/**
 * Enfileira UM turno inbound normal a partir de uma mensagem já gravada.
 *
 * Mesmo evento de um texto novo (`ai_agent.dispatch_requested`), então passa
 * pelo drain — que é quem segura na porta: elegibilidade, grupo, debounce,
 * anti-backlog (se um texto mais novo já estiver na fila, este turno é
 * dispensado) e idempotência por `source_event_id` / entity da mensagem.
 *
 * Usado pela reação ao handoff técnico (derivação que concluiu) e pela
 * devolução do atendimento ao agente quando há inbound pendente.
 */

import type { SupabaseClient } from "@supabase/supabase-js";

import { logger } from "@/lib/logger";

export type ConversaParaDespacho = {
  id: string;
  contact_id: string | null;
  channel_session_id: string | null;
};

export async function reenfileirarTurno(
  admin: SupabaseClient,
  entrada: {
    organizationId: string;
    conversation: ConversaParaDespacho;
    messageId: string;
    requestId: string;
    /** De onde veio o reenfileiramento — telemetria do event_log. */
    source: string;
    motivo?: string;
  },
): Promise<void> {
  const { organizationId, conversation, messageId, requestId, source, motivo } = entrada;
  if (!conversation.contact_id || !conversation.channel_session_id) return;

  const { error } = await admin.rpc("emit_event", {
    p_event_type: "ai_agent.dispatch_requested",
    p_entity_kind: "message",
    p_entity_id: messageId,
    p_payload: {
      organization_id: organizationId,
      conversation_id: conversation.id,
      contact_id: conversation.contact_id,
      channel_session_id: conversation.channel_session_id,
      inbound_message_id: messageId,
    },
    p_metadata: {
      source,
      request_id: requestId,
      ...(motivo ? { motivo } : {}),
    },
    p_organization_id: organizationId,
  });
  if (error) {
    logger.warn("reenfileirar-turno: dispatch nao emitido", {
      source,
      conversation_id: conversation.id,
      message_id: messageId,
      error: error.message,
    });
  }
}

type MsgRow = {
  id: string;
  direction: string;
  sent_via: string | null;
  sent_by_user_id: string | null;
};

/**
 * Outbound que conta como "alguém do time respondeu o cliente".
 *
 * Decisão (Fala42 — aviso de handoff não zera pendência):
 * - Conta: `sent_by_user_id` preenchido, OU `sent_via` em `user` / `external_device`
 *   (fala humana; multi-device às vezes não traz user id).
 * - NÃO conta: `ai` (aviso de transferência da IA), `system`, `automation`,
 *   `crm`. O cliente ainda tem pergunta em aberto.
 */
export function outboundHumanaRespondeu(row: {
  direction: string;
  sent_via?: string | null;
  sent_by_user_id?: string | null;
}): boolean {
  if (row.direction !== "outbound") return false;
  if (row.sent_by_user_id) return true;
  return row.sent_via === "user" || row.sent_via === "external_device";
}

/**
 * A inbound mais recente ainda sem resposta HUMANA depois dela.
 *
 * Outbounds da IA / sistema / automação depois da pergunta do cliente NÃO
 * contam como resposta — o aviso "vou chamar um atendente" não zera a
 * pendência. Só outbound humana zera.
 *
 * Retorna o id da inbound pendente mais nova, ou null se a última fala
 * relevante foi humana ou se não há inbound.
 */
export async function idDaInboundPendenteAposUltimaOutbound(
  admin: SupabaseClient,
  entrada: { organizationId: string; conversationId: string },
): Promise<string | null> {
  const { data, error } = await admin
    .from("messages")
    .select("id, direction, sent_via, sent_by_user_id")
    .eq("organization_id", entrada.organizationId)
    .eq("conversation_id", entrada.conversationId)
    .order("created_at", { ascending: false })
    .limit(50);

  if (error) {
    logger.warn("reenfileirar-turno: nao li mensagens para pendencia", {
      conversation_id: entrada.conversationId,
      error: error.message,
    });
    return null;
  }

  for (const row of (data ?? []) as MsgRow[]) {
    if (row.direction === "outbound") {
      if (outboundHumanaRespondeu(row)) return null;
      continue;
    }
    if (row.direction === "inbound") return row.id;
  }
  return null;
}

/**
 * A inbound mais recente da conversa — usada quando a devolução traz nota
 * nova e precisamos enfileirar um turno mesmo com outbound humana por último.
 */
export async function idDaUltimaInbound(
  admin: SupabaseClient,
  entrada: { organizationId: string; conversationId: string },
): Promise<string | null> {
  const { data, error } = await admin
    .from("messages")
    .select("id")
    .eq("organization_id", entrada.organizationId)
    .eq("conversation_id", entrada.conversationId)
    .eq("direction", "inbound")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    logger.warn("reenfileirar-turno: nao li ultima inbound", {
      conversation_id: entrada.conversationId,
      error: error.message,
    });
    return null;
  }
  const row = data as { id: string } | null;
  return row?.id ?? null;
}

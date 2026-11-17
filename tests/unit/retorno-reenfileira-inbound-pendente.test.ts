/**
 * RETORNO DO HUMANO COM PERGUNTA PENDENTE / NOTA DO OPERADOR.
 *
 * - Aviso de handoff da IA (sent_via=ai) NÃO zera pendência.
 * - Outbound humana por último, sem nota → silêncio.
 * - Outbound humana por último + nota nova → um turno (instrução).
 * - Devolução dupla → mesmo entity_id (dedupe do event path).
 */
import { describe, expect, it, vi } from "vitest";

import { devolverAtendimentoAoAgente } from "@/lib/escalacao/retomada";
import type { Actor } from "@/lib/api/handlers/types";

vi.mock("@/lib/audit", () => ({ audit: vi.fn().mockResolvedValue(undefined) }));

const ORG = "22222222-2222-4222-8222-222222222222";
const CONV = "44444444-4444-4444-8444-444444444444";
const CONTATO = "55555555-5555-4555-8555-555555555555";
const CANAL = "88888888-8888-4888-8888-888888888888";
const ATENDENTE = "11111111-1111-4111-8111-111111111111";
const MSG_INBOUND = "99999999-9999-4999-8999-999999999999";
const MSG_OUTBOUND = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const MSG_AVISO_IA = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

const USUARIO: Actor = { type: "user", id: ATENDENTE, role: "manager" };

type Msg = {
  id: string;
  direction: "inbound" | "outbound";
  created_at: string;
  sent_via?: string | null;
  sent_by_user_id?: string | null;
};

interface Cenario {
  mensagens: Msg[];
  channel_session_id?: string | null;
  status?: string;
  contact_id?: string | null;
  ai_opt_out?: boolean;
  /** Notas internas (conversation_notes) — dispara turno mesmo com outbound humana. */
  notas?: Array<{ body: string; created_by_name: string | null; created_at: string }>;
  service_revision?: number;
}

interface Cap {
  rpc: Array<{ fn: string; args: Record<string, unknown> }>;
  inserts: Array<{ tabela: string; valores: Record<string, unknown> }>;
}

function fazerSupabase(cenario: Cenario, cap: Cap) {
  const conversa = {
    id: CONV,
    contact_id: cenario.contact_id === undefined ? CONTATO : cenario.contact_id,
    channel_session_id:
      cenario.channel_session_id === undefined ? CANAL : cenario.channel_session_id,
    status: cenario.status ?? "claimed",
    assigned_to_user_id: ATENDENTE,
    assignee_kind: "user",
    bot_silenced_until: "infinity",
    service_revision: cenario.service_revision ?? 1,
    current_demanda_id: null,
  };

  const from = (tabela: string) => {
    let ehUpdate = false;
    let filtroDirection: string | null = null;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const chain: any = {
      select: () => chain,
      eq: (coluna: string, valor: unknown) => {
        if (coluna === "direction") filtroDirection = String(valor);
        return chain;
      },
      is: () => chain,
      in: () => chain,
      order: () => chain,
      limit: () => chain,
      update: () => {
        ehUpdate = true;
        return chain;
      },
      insert: (valores: Record<string, unknown>) => {
        cap.inserts.push({ tabela, valores });
        return Promise.resolve({ data: null, error: null });
      },
      maybeSingle: () => {
        if (ehUpdate && tabela === "contacts") {
          return Promise.resolve({ data: { id: CONTATO }, error: null });
        }
        if (ehUpdate && tabela === "conversations") {
          return Promise.resolve({ data: { id: CONV }, error: null });
        }
        if (tabela === "conversations") {
          return Promise.resolve({ data: conversa, error: null });
        }
        if (tabela === "contacts") {
          return Promise.resolve({
            data: { ai_opt_out: cenario.ai_opt_out ?? false, force_human: true },
            error: null,
          });
        }
        if (tabela === "lead_checkpoints") {
          return Promise.resolve({ data: null, error: null });
        }
        if (tabela === "crm_pipelines") {
          return Promise.resolve({ data: { id: "pipe-1" }, error: null });
        }
        if (tabela === "messages" && filtroDirection === "inbound") {
          const inbound = cenario.mensagens.find((m) => m.direction === "inbound");
          return Promise.resolve({ data: inbound ? { id: inbound.id } : null, error: null });
        }
        if (tabela === "messages") {
          // última outbound ai (continuidade)
          const ai = cenario.mensagens.find(
            (m) => m.direction === "outbound" && m.sent_via === "ai",
          );
          return Promise.resolve({
            data: ai ? { created_at: ai.created_at } : null,
            error: null,
          });
        }
        return Promise.resolve({ data: null, error: null });
      },
      then: (res: (v: unknown) => unknown) => {
        if (tabela === "messages") {
          return Promise.resolve({ data: cenario.mensagens, error: null }).then(res);
        }
        if (tabela === "conversation_notes") {
          return Promise.resolve({ data: cenario.notas ?? [], error: null }).then(res);
        }
        return Promise.resolve({ data: [], error: null }).then(res);
      },
    };
    return chain;
  };

  return {
    from,
    rpc: (fn: string, args: Record<string, unknown>) => {
      cap.rpc.push({ fn, args });
      if (fn === "emit_event") return Promise.resolve({ data: null, error: null });
      return Promise.resolve({ data: [{ id: CONV }], error: null });
    },
  };
}

async function retomar(
  cenario: Cenario,
  cap: Cap,
  extra: { inboundMessageIdParaDespacho?: string } = {},
) {
  return devolverAtendimentoAoAgente(
    {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      supabase: fazerSupabase(cenario, cap) as any,
      organizationId: ORG,
      actor: USUARIO,
      requestId: "req-retorno-1",
    },
    { conversationId: CONV, ...extra },
  );
}

function dispatches(cap: Cap) {
  return cap.rpc.filter(
    (r) => r.fn === "emit_event" && r.args.p_event_type === "ai_agent.dispatch_requested",
  );
}

describe("retorno do humano reenfileira inbound pendente", () => {
  it("pergunta pendente → enfileira exatamente um turno", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
          {
            id: MSG_OUTBOUND,
            direction: "outbound",
            sent_via: "user",
            sent_by_user_id: ATENDENTE,
            created_at: "2026-09-06T11:00:00Z",
          },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args).toMatchObject({
      p_entity_kind: "message",
      p_entity_id: MSG_INBOUND,
      p_payload: expect.objectContaining({
        inbound_message_id: MSG_INBOUND,
        conversation_id: CONV,
        contact_id: CONTATO,
        channel_session_id: CANAL,
      }),
      p_metadata: expect.objectContaining({
        source: "escalacao.retomada",
        motivo: "retorno_com_inbound_pendente",
      }),
    });
  });

  it("aviso de handoff da IA por último + pergunta pendente → enfileira um turno", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          {
            id: MSG_AVISO_IA,
            direction: "outbound",
            sent_via: "ai",
            sent_by_user_id: null,
            created_at: "2026-09-06T12:05:00Z",
          },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
    expect(dispatches(cap)[0]!.args.p_metadata).toMatchObject({
      motivo: "retorno_com_inbound_pendente",
    });
  });

  it("saudação da IA por último + rajada com pergunta → um turno (dedupe por entity)", async () => {
    // Caso real: "Olá" + "Como funciona o fiado?" → IA só "Oi, Bruna!".
    const msgOla = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          {
            id: MSG_AVISO_IA,
            direction: "outbound",
            sent_via: "ai",
            sent_by_user_id: null,
            created_at: "2026-09-06T12:06:00Z",
          },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:05:00Z" },
          { id: msgOla, direction: "inbound", created_at: "2026-09-06T12:04:00Z" },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
    expect(dispatches(cap)[0]!.args.p_metadata).toMatchObject({
      motivo: "retorno_com_inbound_pendente",
    });
  });

  it("atendente falou por último, sem nota → não enfileira", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          {
            id: MSG_OUTBOUND,
            direction: "outbound",
            sent_via: "user",
            sent_by_user_id: ATENDENTE,
            created_at: "2026-09-06T12:00:00Z",
          },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T11:00:00Z" },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(0);
  });

  it("humano respondeu por último + nota nova → um turno com instrução no checkpoint", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          {
            id: MSG_OUTBOUND,
            direction: "outbound",
            sent_via: "user",
            sent_by_user_id: ATENDENTE,
            created_at: "2026-09-06T12:00:00Z",
          },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T11:00:00Z" },
        ],
        notas: [
          {
            body: "responda o que o cliente está perguntando, o preço pode pegar na tabela",
            created_by_name: "Ana",
            created_at: "2026-09-06T12:10:00Z",
          },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args).toMatchObject({
      p_entity_id: MSG_INBOUND,
      p_metadata: expect.objectContaining({ motivo: "retorno_com_nota_do_operador" }),
    });

    const checkpoint = cap.inserts.find((i) => i.tabela === "lead_checkpoints");
    expect(checkpoint).toBeDefined();
    expect(checkpoint!.valores).toMatchObject({
      conversation_id: CONV,
      service_revision: 1,
    });
    const resumo = String(checkpoint!.valores.rolling_summary);
    expect(resumo).toContain("## Instrução do operador");
    expect(resumo).toMatch(/KB e as regras VENCEM/i);
    expect(resumo).toContain("preço pode pegar na tabela");
  });

  it("id forçado (handoff técnico) despacha mesmo com outbound depois — aviso de handoff", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    const res = await retomar(
      {
        mensagens: [
          {
            id: MSG_OUTBOUND,
            direction: "outbound",
            sent_via: "ai",
            created_at: "2026-09-06T12:00:00Z",
          },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T11:00:00Z" },
        ],
      },
      cap,
      { inboundMessageIdParaDespacho: MSG_INBOUND },
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args).toMatchObject({
      p_entity_id: MSG_INBOUND,
      p_metadata: expect.objectContaining({
        motivo: "retorno_com_inbound_forcada",
      }),
    });
  });

  it("devolução dupla com a mesma pendente → mesmo entity_id (um turno lógico)", async () => {
    const cenario: Cenario = {
      mensagens: [
        {
          id: MSG_AVISO_IA,
          direction: "outbound",
          sent_via: "ai",
          created_at: "2026-09-06T12:05:00Z",
        },
        { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
      ],
    };
    const cap1: Cap = { rpc: [], inserts: [] };
    const cap2: Cap = { rpc: [], inserts: [] };
    await retomar(cenario, cap1);
    await retomar(cenario, cap2);

    expect(dispatches(cap1)).toHaveLength(1);
    expect(dispatches(cap2)).toHaveLength(1);
    expect(dispatches(cap1)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
    expect(dispatches(cap2)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
  });

  it("mensagem 'vista' por turno coalescido mas sem outbound humana → elegível no retorno", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    await retomar(
      {
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:05:00Z" },
          {
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            direction: "inbound",
            created_at: "2026-09-06T12:00:00Z",
          },
        ],
      },
      cap,
    );

    expect(dispatches(cap)).toHaveLength(1);
    expect(dispatches(cap)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
  });

  it("sem canal → não enfileira", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    await retomar(
      {
        channel_session_id: null,
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
        ],
      },
      cap,
    );
    expect(dispatches(cap)).toHaveLength(0);
  });

  it("conversa fechada → não enfileira", async () => {
    const cap: Cap = { rpc: [], inserts: [] };
    await retomar(
      {
        status: "closed",
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
        ],
      },
      cap,
    );
    expect(dispatches(cap)).toHaveLength(0);
  });
});

/**
 * RETORNO DO HUMANO COM PERGUNTA PENDENTE.
 *
 * Quando o atendente devolve a conversa à IA e há inbound depois da última
 * outbound, `devolverAtendimentoAoAgente` enfileira UM turno inbound normal.
 * Se o atendente falou por último, não enfileira. Critério = inbound após
 * última outbound — não `ultima_inbound_vista_em`.
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

const USUARIO: Actor = { type: "user", id: ATENDENTE, role: "manager" };

type Msg = { id: string; direction: "inbound" | "outbound"; created_at: string };

interface Cenario {
  mensagens: Msg[];
  channel_session_id?: string | null;
  status?: string;
  contact_id?: string | null;
  ai_opt_out?: boolean;
}

interface Cap {
  rpc: Array<{ fn: string; args: Record<string, unknown> }>;
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
  };

  const from = (tabela: string) => {
    let ehUpdate = false;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const chain: any = {
      select: () => chain,
      eq: () => chain,
      is: () => chain,
      in: () => chain,
      order: () => chain,
      limit: () => chain,
      update: () => {
        ehUpdate = true;
        return chain;
      },
      insert: () => Promise.resolve({ data: null, error: null }),
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
        return Promise.resolve({ data: null, error: null });
      },
      then: (res: (v: unknown) => unknown) => {
        if (tabela === "messages") {
          return Promise.resolve({ data: cenario.mensagens, error: null }).then(res);
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
    const cap: Cap = { rpc: [] };
    const res = await retomar(
      {
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
          { id: MSG_OUTBOUND, direction: "outbound", created_at: "2026-09-06T11:00:00Z" },
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

  it("atendente falou por último → não enfileira", async () => {
    const cap: Cap = { rpc: [] };
    const res = await retomar(
      {
        mensagens: [
          { id: MSG_OUTBOUND, direction: "outbound", created_at: "2026-09-06T12:00:00Z" },
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T11:00:00Z" },
        ],
      },
      cap,
    );

    expect(res.ok).toBe(true);
    expect(dispatches(cap)).toHaveLength(0);
  });

  it("id forçado (handoff técnico) despacha mesmo com outbound depois — aviso de handoff", async () => {
    const cap: Cap = { rpc: [] };
    const res = await retomar(
      {
        mensagens: [
          { id: MSG_OUTBOUND, direction: "outbound", created_at: "2026-09-06T12:00:00Z" },
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

  it("retorno repetido com a mesma pendente → mesmo entity_id (dedupe do event path)", async () => {
    const cenario: Cenario = {
      mensagens: [
        { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:00:00Z" },
      ],
    };
    const cap1: Cap = { rpc: [] };
    const cap2: Cap = { rpc: [] };
    await retomar(cenario, cap1);
    await retomar(cenario, cap2);

    expect(dispatches(cap1)).toHaveLength(1);
    expect(dispatches(cap2)).toHaveLength(1);
    expect(dispatches(cap1)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
    expect(dispatches(cap2)[0]!.args.p_entity_id).toBe(MSG_INBOUND);
  });

  it("mensagem 'vista' por turno coalescido mas sem outbound → elegível no retorno", async () => {
    // Só inbounds depois da (ausência de) outbound nossa: o critério NÃO olha
    // ultima_inbound_vista_em — se o cliente falou e ninguém do nosso lado
    // respondeu, o retorno despacha.
    const cap: Cap = { rpc: [] };
    await retomar(
      {
        mensagens: [
          { id: MSG_INBOUND, direction: "inbound", created_at: "2026-09-06T12:05:00Z" },
          {
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
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
    const cap: Cap = { rpc: [] };
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
    const cap: Cap = { rpc: [] };
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

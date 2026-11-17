/**
 * Pendências do cliente desde a ÚLTIMA RESPOSTA HUMANA.
 *
 * Aviso/saudação da IA no meio NÃO zera a lista — o bloco "Mensagem atual"
 * na devolução precisa trazer a pergunta que ficou sem resposta.
 */
import { describe, expect, it } from "vitest";

import {
  inboundsNaoRespondidos,
  inboundsNaoRespondidosDetalhados,
} from "@/lib/agent-engine/agent/inbounds-nao-respondidos";
import { buildOpeningMessage } from "@/lib/agent-engine/agent/abertura/ritual";
import type { LeadContext } from "@/lib/agent-engine/edge/crm/get-lead-context";

const OLA = "Olá";
const FIADO = "Como funciona o fiado?";

function msgs(
  rows: LeadContext["messages"],
): LeadContext {
  return {
    lead_id: "11111111-1111-4111-8111-111111111111",
    contact: { name: "Bruna", phone: null, email: null, tags: [], is_blocked: false },
    conversation_id: "22222222-2222-4222-8222-222222222222",
    last_human_decision: null,
    messages: rows,
  } as unknown as LeadContext;
}

describe("inbounds pendentes após outbound da IA", () => {
  it("saudação da IA não apaga Olá + pergunta do cliente", () => {
    const historico = [
      { direction: "inbound" as const, body: OLA, sent_at: "2026-09-06T09:03:00-04:00" },
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:04-04:00" },
      {
        direction: "outbound" as const,
        body: "Oi, Bruna!",
        sent_at: "2026-09-06T09:03:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([OLA, FIADO]);
    expect(inboundsNaoRespondidosDetalhados(historico).map((p) => p.body)).toEqual([OLA, FIADO]);
  });

  it("outbound humana corta a pendência", () => {
    const historico = [
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
      {
        direction: "outbound" as const,
        body: "O fiado funciona assim…",
        sent_at: "2026-09-06T09:04:00-04:00",
        sent_via: "user",
        sent_by_user_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([]);
  });

  it("devolução: última bolha da IA + pergunta pendente → prompt traz a pergunta", () => {
    const contexto = msgs([
      { direction: "inbound", body: OLA, sent_at: "2026-09-06T09:03:00-04:00" },
      { direction: "inbound", body: FIADO, sent_at: "2026-09-06T09:03:04-04:00" },
      {
        direction: "outbound",
        body: "Oi, Bruna!",
        sent_at: "2026-09-06T09:03:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
    ]);
    const abertura = buildOpeningMessage(null, null, contexto, "sem notas", false, [], "", FIADO);
    expect(abertura).toContain(FIADO);
    expect(abertura).toContain(OLA);
    expect(abertura).toMatch(/Responda a TODAS/i);
  });

  it("sem autoria (fixture legado): qualquer outbound ainda corta — não inventa pendência", () => {
    const historico = [
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
      { direction: "outbound" as const, body: "Oi!", sent_at: "2026-09-06T09:03:10-04:00" },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([]);
  });
});

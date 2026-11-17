/**
 * Corte das pendentes: clássico no turno normal / opt-out; última humana só
 * na devolução (`corte: 'ultima_humana'`).
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
const OPT_OUT = "PARAR";

function msgs(rows: LeadContext["messages"]): LeadContext {
  return {
    lead_id: "11111111-1111-4111-8111-111111111111",
    contact: { name: "Bruna", phone: null, email: null, tags: [], is_blocked: false },
    conversation_id: "22222222-2222-4222-8222-222222222222",
    last_human_decision: null,
    messages: rows,
  } as unknown as LeadContext;
}

describe("inbounds — corte clássico (turno normal / opt-out)", () => {
  it("(a) conversa só-IA com 3 trocas + nova inbound → lista só a nova", () => {
    const historico = [
      { direction: "inbound" as const, body: "Oi", sent_at: "2026-09-06T09:00:00-04:00" },
      {
        direction: "outbound" as const,
        body: "Olá!",
        sent_at: "2026-09-06T09:00:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
      { direction: "inbound" as const, body: "Quanto custa?", sent_at: "2026-09-06T09:01:00-04:00" },
      {
        direction: "outbound" as const,
        body: "R$ 10.",
        sent_at: "2026-09-06T09:01:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
      { direction: "inbound" as const, body: "E o prazo?", sent_at: "2026-09-06T09:02:00-04:00" },
      {
        direction: "outbound" as const,
        body: "2 dias.",
        sent_at: "2026-09-06T09:02:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([FIADO]);
    expect(inboundsNaoRespondidos(historico, { corte: "classico" })).toEqual([FIADO]);

    const abertura = buildOpeningMessage(
      null,
      null,
      msgs(historico),
      "sem notas",
      false,
      [],
      "",
      FIADO,
    );
    const blocoAtual = abertura.slice(abertura.indexOf("## Mensagem atual"));
    expect(blocoAtual).toContain(JSON.stringify({ texto: FIADO }));
    expect(blocoAtual).not.toContain("Quanto custa?");
    expect(blocoAtual).toContain("Responda a ESTA mensagem agora.");
    expect(blocoAtual).not.toMatch(/Responda a TODAS/i);
  });

  it("(b) aviso de escalação por último + pergunta pendente → turno normal lista a pergunta", () => {
    const historico = [
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
      {
        direction: "outbound" as const,
        body: "Vou chamar um atendente para te ajudar.",
        sent_at: "2026-09-06T09:03:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
        aviso_de_escalacao: true,
      },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([FIADO]);
    const abertura = buildOpeningMessage(null, null, msgs(historico), "sem notas", false, [], "", FIADO);
    expect(abertura).toContain(FIADO);
  });

  it("(d) opt-out antigo já respondido pela IA não redispara (corte clássico)", () => {
    const historico = [
      { direction: "inbound" as const, body: OPT_OUT, sent_at: "2026-09-06T09:00:00-04:00" },
      {
        direction: "outbound" as const,
        body: "Ok, não mando mais.",
        sent_at: "2026-09-06T09:00:10-04:00",
        sent_via: "ai",
        sent_by_user_id: null,
      },
      { direction: "inbound" as const, body: "oi de novo", sent_at: "2026-09-06T09:03:00-04:00" },
    ];
    // Opt-out / métricas usam o default clássico — PARAR já respondido some.
    expect(inboundsNaoRespondidos(historico)).toEqual(["oi de novo"]);
    expect(inboundsNaoRespondidos(historico)).not.toContain(OPT_OUT);
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
    expect(inboundsNaoRespondidos(historico, { corte: "ultima_humana" })).toEqual([]);
  });

  it("sem autoria (fixture legado): qualquer outbound ainda corta", () => {
    const historico = [
      { direction: "inbound" as const, body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
      { direction: "outbound" as const, body: "Oi!", sent_at: "2026-09-06T09:03:10-04:00" },
    ];
    expect(inboundsNaoRespondidos(historico)).toEqual([]);
    expect(inboundsNaoRespondidos(historico, { corte: "ultima_humana" })).toEqual([]);
  });
});

describe("inbounds — corte ultima_humana (só devolução)", () => {
  it("(c) Olá + fiado + Oi Bruna da IA → lista as duas", () => {
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
    expect(inboundsNaoRespondidos(historico, { corte: "ultima_humana" })).toEqual([OLA, FIADO]);
    expect(inboundsNaoRespondidosDetalhados(historico, { corte: "ultima_humana" }).map((p) => p.body)).toEqual([
      OLA,
      FIADO,
    ]);
    // No turno NORMAL o default clássico corta na saudação da IA.
    expect(inboundsNaoRespondidos(historico)).toEqual([]);

    const abertura = buildOpeningMessage(
      null,
      null,
      msgs(historico),
      "sem notas",
      false,
      [],
      "",
      FIADO,
      undefined,
      "",
      "json",
      "",
      "ultima_humana",
    );
    expect(abertura).toContain(FIADO);
    expect(abertura).toContain(OLA);
    expect(abertura).toMatch(/Responda a TODAS/i);
  });
});

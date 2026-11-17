/**
 * A RAJADA NO PROMPT — o bloco "## Mensagem atual" lista TODAS as inbounds
 * pendentes quando o drain coalesceou, cada uma num JSON separado.
 *
 * O pin do job (currentInboundText) sozinho respondia só a 1ª ("Olá") e
 * calava a pergunta concreta ("Como funciona o fiado?"). Com UMA mensagem o
 * texto do prompt permanece BYTE A BYTE o de sempre — vigiado pelos testes
 * existentes sem alteração.
 */
import { describe, expect, it } from "vitest";

import { buildOpeningMessage } from "@/lib/agent-engine/agent/abertura/ritual";
import type { LeadContext } from "@/lib/agent-engine/edge/crm/get-lead-context";

const OLA = "Olá";
const FIADO = "Como funciona o fiado?";

function contextoCom(
  messages: LeadContext["messages"],
): LeadContext {
  return {
    lead_id: "11111111-1111-4111-8111-111111111111",
    contact: { name: "Cristiano", phone: null, email: null, tags: [], is_blocked: false },
    conversation_id: "22222222-2222-4222-8222-222222222222",
    last_human_decision: null,
    messages,
  } as unknown as LeadContext;
}

describe("rajada no bloco Mensagem atual", () => {
  it("Olá + Como funciona o fiado?: bloco traz as duas + instrução de responder a todas", () => {
    const contexto = contextoCom([
      { direction: "outbound", body: "Oi!", sent_at: "2026-09-06T09:00:00-04:00" },
      { direction: "inbound", body: OLA, sent_at: "2026-09-06T09:03:00-04:00" },
      { direction: "inbound", body: FIADO, sent_at: "2026-09-06T09:03:04-04:00" },
    ]);

    const abertura = buildOpeningMessage(null, null, contexto, "sem notas", false, [], "", OLA);

    expect(abertura).toContain("## Mensagem atual do cliente — fonte prioritária");
    expect(abertura).toContain('{"texto":"Olá"}');
    expect(abertura).toContain('{"texto":"Como funciona o fiado?"}');
    expect(abertura).toMatch(/Responda a TODAS numa única resposta/i);
    expect(abertura).toMatch(/Priorize pergunta ou pedido concreto sobre saudação/i);
    // Nunca um JSON só com os dois textos emendados.
    expect(abertura).not.toContain(`"texto":"${OLA}\\n${FIADO}"`);
    expect(abertura).not.toContain(`"texto":"${OLA} ${FIADO}"`);
  });

  it("mensagem única: prompt idêntico ao caminho de sempre (uma só, instrução ESTA)", () => {
    const contexto = contextoCom([
      { direction: "outbound", body: "Oi!", sent_at: "2026-09-06T09:00:00-04:00" },
      { direction: "inbound", body: FIADO, sent_at: "2026-09-06T09:03:00-04:00" },
    ]);

    const abertura = buildOpeningMessage(null, null, contexto, "sem notas", false, [], "", FIADO);

    expect(abertura).toContain("Responda a ESTA mensagem agora.");
    expect(abertura).not.toMatch(/Responda a TODAS/i);
    expect(abertura).toContain(JSON.stringify({ texto: FIADO }));
    // Uma ocorrência do JSON — não lista.
    expect(abertura.split(JSON.stringify({ texto: FIADO })).length - 1).toBe(1);
  });

  it("grupo com 2 remetentes na rajada: remetente por item", () => {
    const dona = { name: "Dona", phone: "+5511999990000" };
    const cliente = { name: "Cliente", phone: "+5511888880000" };
    const contexto = contextoCom([
      { direction: "outbound", body: "Bom dia!", sent_at: "2026-09-06T09:00:00-04:00" },
      {
        direction: "inbound",
        body: "Oi pessoal",
        sent_at: "2026-09-06T09:03:00-04:00",
        sender: dona,
      },
      {
        direction: "inbound",
        body: "Quanto custa o metro?",
        sent_at: "2026-09-06T09:03:05-04:00",
        sender: cliente,
      },
    ]);

    const abertura = buildOpeningMessage(
      null,
      null,
      contexto,
      "sem notas",
      false,
      [],
      "",
      "Oi pessoal",
      dona,
    );

    expect(abertura).toContain('"texto":"Oi pessoal"');
    expect(abertura).toContain('"texto":"Quanto custa o metro?"');
    expect(abertura).toContain('"remetente":"Dona · +5511999990000"');
    expect(abertura).toContain('"remetente":"Cliente · +5511888880000"');
    expect(abertura).toMatch(/Responda a TODAS numa única resposta/i);
  });

  it("pin ausente do histórico atrasado ainda entra sozinho (sem inventar multi)", () => {
    const contexto = contextoCom([]);
    const abertura = buildOpeningMessage(null, null, contexto, "sem notas", false, [], "", FIADO);
    expect(abertura).toContain(JSON.stringify({ texto: FIADO }));
    expect(abertura).toContain("Responda a ESTA mensagem agora.");
    expect(abertura).not.toMatch(/Responda a TODAS/i);
  });

  it("devolução: Olá + fiado + saudação da IA → lista as duas (corte ultima_humana)", () => {
    // Caso real na DEVOLUÇÃO: IA respondeu só "Oi, Bruna!" e a pergunta ficou
    // sem resposta. Turno normal usaria clássico (cortaria); a devolução passa
    // `ultima_humana` via payload do job.
    const contexto = contextoCom([
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

    const abertura = buildOpeningMessage(
      null,
      null,
      contexto,
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

    expect(abertura).toContain('{"texto":"Olá"}');
    expect(abertura).toContain('{"texto":"Como funciona o fiado?"}');
    expect(abertura).toMatch(/Responda a TODAS numa única resposta/i);
    expect(abertura).toMatch(/saudação sozinha NÃO basta/i);
    expect(abertura).toMatch(/cada pergunta\/pedido concreto/i);
  });
});

/**
 * Inbounds ainda sem resposta nossa — a lista que a rajada, o handoff e o
 * opt-out leem.
 *
 * Mora fora de `inbound-turn.ts` de propósito: `abertura/ritual.ts` precisa
 * montar o bloco "Mensagem atual" com a rajada inteira, e a cerca do recorte 1
 * proíbe o ritual de importar o turno (ciclo).
 *
 * ## Por que uma LISTA, e não um texto emendado
 *
 * `ehPalavraIsolada` (lib/opt-out/deteccao.ts) exige que a mensagem INTEIRA seja
 * a palavra-chave — é assim que "PARAR" descadastra e "tem como parar a dor?"
 * não. Emendar as mensagens da rajada num texto só destruiria exatamente essa
 * propriedade: "oi\nPARAR" não é palavra isolada, e o opt-out deixaria de
 * disparar. Quem consome isto roda o detector POR MENSAGEM.
 *
 * O corte é a última OUTBOUND (resposta de humano conta — ela também é do nosso
 * lado). Sem nenhuma outbound na janela, tudo que o cliente disse segue sem
 * resposta, e é isso que a lista devolve.
 */

import type { LeadContextMessage } from "../edge/crm/get-lead-context";

/** Uma inbound pendente com o remetente de grupo, quando houver. */
export type InboundPendente = {
  body: string;
  sender?: { name: string | null; phone: string | null };
};

/**
 * As inbounds depois da última outbound, com remetente (grupo) quando existe.
 * Ordem cronológica — a mais antiga primeiro.
 */
export function inboundsNaoRespondidosDetalhados(
  messages: readonly LeadContextMessage[],
): InboundPendente[] {
  const pendentes: InboundPendente[] = [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i];
    if (m === undefined) continue;
    if (m.direction === "outbound") break;
    if (m.body.trim() !== "") {
      pendentes.unshift({
        body: m.body,
        ...(m.sender !== undefined ? { sender: m.sender } : {}),
      });
    }
  }
  return pendentes;
}

/** Só os textos — handoff, opt-out e urgência leem por mensagem. */
export function inboundsNaoRespondidos(messages: readonly LeadContextMessage[]): string[] {
  return inboundsNaoRespondidosDetalhados(messages).map((p) => p.body);
}

/**
 * O que o bloco "Mensagem atual" deve listar neste turno.
 *
 * - Com pin do job presente no histórico: a rajada inteira (todas as pendentes).
 * - Com pin ausente do histórico (leitura atrasada OU registro concorrente):
 *   só o pin — não mescla estranhos (o pin vence o sequestro do turno).
 * - Sem pin: as pendentes do histórico.
 */
export function pendentesDaMensagemAtual(
  messages: readonly LeadContextMessage[],
  currentInboundText?: string,
  currentInboundSender?: { name: string | null; phone: string | null },
): InboundPendente[] {
  const doHistorico = inboundsNaoRespondidosDetalhados(messages);

  if (currentInboundText === undefined) return doHistorico;
  if (currentInboundText.trim() === "") return [];

  const pin: InboundPendente = {
    body: currentInboundText,
    ...(currentInboundSender !== undefined ? { sender: currentInboundSender } : {}),
  };

  const idx = doHistorico.findIndex((p) => p.body === currentInboundText);
  if (idx < 0) {
    // Histórico atrasado (vazio) ou registro concorrente: o pin é a fonte.
    return [pin];
  }

  // Pin está no histórico — a rajada inteira. Remetente do job vence o do histórico
  // na posição do pin (é a consulta canônica do job).
  if (currentInboundSender === undefined) return doHistorico;
  return doHistorico.map((p, i) => (i === idx ? { ...p, sender: currentInboundSender } : p));
}

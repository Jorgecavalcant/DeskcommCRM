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
 * ## Dois cortes, um parâmetro — sem estado global
 *
 * - `classico` (default): qualquer outbound corta a lista, COM UMA exceção —
 *   o aviso de transferência (`aviso_de_escalacao === true`) NÃO corta. Opt-out,
 *   filtro comercial restrito, métricas e turno normal usam este.
 * - `ultima_humana`: só outbound humana corta (mesmo critério de
 *   `outboundHumanaRespondeu`). Usado APENAS no turno enfileirado pela
 *   devolução (`corte_pendencias: 'ultima_humana'` no payload do job), para a
 *   saudação "Oi, Bruna!" não esconder a pergunta pendente.
 * - Sem autoria na mensagem (fixtures antigas), nos dois modos qualquer
 *   outbound corta — não inventa pendência onde o dado não existe.
 */

import type { LeadContextMessage } from "../edge/crm/get-lead-context";
import { outboundHumanaRespondeu } from "@/lib/escalacao/reenfileirar-turno";

/** Uma inbound pendente com o remetente de grupo, quando houver. */
export type InboundPendente = {
  body: string;
  sender?: { name: string | null; phone: string | null };
};

/** Como a lista de pendentes é cortada neste consumo. */
export type CorteDePendencias = "classico" | "ultima_humana";

export type OpcoesDePendencias = {
  corte?: CorteDePendencias;
};

/**
 * A outbound corta a lista neste modo?
 * - Aviso de transferência nunca corta (em nenhum modo).
 * - `classico`: qualquer outra outbound corta.
 * - `ultima_humana`: só humana corta; sem autoria, qualquer outbound corta.
 */
function outboundCortaPendencia(
  m: LeadContextMessage,
  corte: CorteDePendencias,
): boolean {
  if (m.direction !== "outbound") return false;
  if (m.aviso_de_escalacao === true) return false;

  if (corte === "classico") return true;

  const temAutoria = m.sent_via !== undefined || m.sent_by_user_id !== undefined;
  if (!temAutoria) return true;
  return outboundHumanaRespondeu(m);
}

/**
 * As inbounds depois do corte, com remetente (grupo) quando existe.
 * Ordem cronológica — a mais antiga primeiro.
 */
export function inboundsNaoRespondidosDetalhados(
  messages: readonly LeadContextMessage[],
  opcoes?: OpcoesDePendencias,
): InboundPendente[] {
  const corte: CorteDePendencias = opcoes?.corte ?? "classico";
  const pendentes: InboundPendente[] = [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i];
    if (m === undefined) continue;
    if (m.direction === "outbound") {
      if (outboundCortaPendencia(m, corte)) break;
      continue;
    }
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
export function inboundsNaoRespondidos(
  messages: readonly LeadContextMessage[],
  opcoes?: OpcoesDePendencias,
): string[] {
  return inboundsNaoRespondidosDetalhados(messages, opcoes).map((p) => p.body);
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
  opcoes?: OpcoesDePendencias,
): InboundPendente[] {
  const doHistorico = inboundsNaoRespondidosDetalhados(messages, opcoes);

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

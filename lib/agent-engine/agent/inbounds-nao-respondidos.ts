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
 * ## O corte: última resposta HUMANA
 *
 * Alinhado a `outboundHumanaRespondeu` (reenfileirar-turno): aviso da IA,
 * saudação automática, system/automation/crm NÃO zeram a pendência. Só outbound
 * humana (`sent_by_user_id` ou `sent_via` user/external_device) corta a lista.
 * Sem autoria na mensagem (fixtures antigas), o corte clássico vale — qualquer
 * outbound quebra, para não inventar pendência onde o dado não existe.
 */

import type { LeadContextMessage } from "../edge/crm/get-lead-context";
import { outboundHumanaRespondeu } from "@/lib/escalacao/reenfileirar-turno";

/** Uma inbound pendente com o remetente de grupo, quando houver. */
export type InboundPendente = {
  body: string;
  sender?: { name: string | null; phone: string | null };
};

/**
 * A outbound corta a lista de pendentes?
 * - Com autoria (`sent_via` / `sent_by_user_id`): só humana corta.
 * - Sem autoria (legado / fixture): qualquer outbound corta (comportamento clássico).
 */
function outboundCortaPendencia(m: LeadContextMessage): boolean {
  if (m.direction !== "outbound") return false;
  const temAutoria = m.sent_via !== undefined || m.sent_by_user_id !== undefined;
  if (!temAutoria) return true;
  return outboundHumanaRespondeu(m);
}

/**
 * As inbounds depois da última resposta humana, com remetente (grupo) quando existe.
 * Ordem cronológica — a mais antiga primeiro.
 */
export function inboundsNaoRespondidosDetalhados(
  messages: readonly LeadContextMessage[],
): InboundPendente[] {
  const pendentes: InboundPendente[] = [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const m = messages[i];
    if (m === undefined) continue;
    if (m.direction === "outbound") {
      if (outboundCortaPendencia(m)) break;
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

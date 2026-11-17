/**
 * O SCHEMA DA FERRAMENTA TEM DOIS LADOS, E ELES PRECISAM ANDAR JUNTOS.
 *
 * ## Por que existem dois
 *
 * `AGENT_TOOL_DEFS.request_human_handoff.inputSchema` (`inbound-turn.ts`) é o
 * schema LARGO que o SDK entrega ao modelo: é ele que o modelo lê para saber o
 * que pode escrever, inclusive os `.describe()` de cada campo. Já
 * `requestHumanHandoffInputSchema` (`human-handoff.ts`) é a whitelist
 * `.strictObject()` que valida o payload de verdade, com guard de poluição de
 * protótipo por cima.
 *
 * ## O defeito que este arquivo impede
 *
 * Campo acrescentado só no LARGO: o modelo preenche, a whitelist recusa, e a
 * ferramenta devolve erro de ENSINO — a cada chamada, para sempre, num caminho
 * que ninguém exercita em teste manual porque é o modelo quem o aciona.
 * Campo acrescentado só na WHITELIST: o modelo nunca sabe que ele existe, e o
 * campo fica órfão — o mesmo defeito que `refund_mention` já é neste repositório.
 *
 * ## Por que os campos importam
 *
 * Os `.describe()` são o ÚNICO lugar onde o modelo aprende o que escrever. Um
 * campo sem descrição é um campo que ele preenche por adivinhação — e o que ele
 * escrever aqui é literalmente tudo que a pessoa que assumir a conversa vai ver.
 */
import { describe, expect, it } from "vitest";
import { z } from "zod";

import { AGENT_TOOL_DEFS } from "@/lib/agent-engine/agent/inbound-turn";
import { requestHumanHandoffInputSchema } from "@/lib/agent-engine/agent/human-handoff";

/** As chaves de um `ZodObject`, seja ele `.strictObject` ou `.passthrough()`. */
function chaves(schema: z.ZodType): string[] {
  const forma = (schema as unknown as { def?: { shape?: Record<string, unknown> } }).def?.shape;
  expect(forma, "o schema deixou de ser um objeto — a sonda ficaria cega").toBeDefined();
  return Object.keys(forma ?? {}).sort();
}

const LARGO = AGENT_TOOL_DEFS.request_human_handoff.inputSchema as unknown as z.ZodType;

describe("os dois lados do schema da tool de passagem", () => {
  it("as chaves são o MESMO conjunto", () => {
    expect(chaves(LARGO)).toEqual(chaves(requestHumanHandoffInputSchema as unknown as z.ZodType));
  });

  it("a sonda não é vazia: o conjunto tem o motivo e os campos que a pessoa vai ler", () => {
    // GUARDA DE VACUIDADE. Sem ela, dois schemas VAZIOS passariam no caso acima.
    expect(chaves(LARGO)).toEqual(["cliente_quer", "motivo_codigo", "o_que_tentei", "por_que", "reason"]);
  });

  it("todo campo do lado que o modelo lê tem `.describe()`", () => {
    const forma = (LARGO as unknown as { def: { shape: Record<string, z.ZodType> } }).def.shape;
    for (const [nome, campo] of Object.entries(forma)) {
      const descricao = (campo as unknown as { description?: string }).description;
      expect(descricao ?? "", `o campo ${nome} não ensina nada ao modelo`).not.toBe("");
    }
  });

  it("a descrição da tool manda preencher os campos — é a única instrução que o modelo recebe", () => {
    const d = AGENT_TOOL_DEFS.request_human_handoff.description;
    expect(d).toContain("por_que");
    expect(d).toContain("o_que_tentei");
    expect(d).toContain("cliente_quer");
  });

  it("a whitelist continua ESTRITA: campo forjado é recusado, não removido em silêncio", () => {
    const r = requestHumanHandoffInputSchema.safeParse({ por_que: "não consigo", inventado: 1 });
    expect(r.success, "strip silencioso esconde do modelo que ele escreveu errado").toBe(false);
  });

  it("o payload que o modelo mais escreve passa inteiro", () => {
    const r = requestHumanHandoffInputSchema.safeParse({
      por_que: "o desconto que ele pede está fora da minha alçada",
      o_que_tentei: [{ o_que: "busquei a política na base", desfecho: "o teto é 10%" }],
      cliente_quer: "20% de desconto na renovação",
    });
    expect(r.success).toBe(true);
  });

  it("`reason` sobrevive como sinônimo — chamador antigo não quebra", () => {
    expect(requestHumanHandoffInputSchema.safeParse({ reason: "cliente irritado" }).success).toBe(
      true,
    );
  });

  it.each(["requested_human", "critical_stage"])("os dois lados aceitam %s", (motivo_codigo) => {
    const payload = { motivo_codigo, por_que: "a equipe precisa concluir esta etapa" };
    expect(LARGO.parse(payload)).toEqual(payload);
    expect(requestHumanHandoffInputSchema.parse(payload)).toEqual(payload);
  });

  it("o schema exposto ao modelo declara o enum (não string livre)", () => {
    const forma = (LARGO as unknown as { def: { shape: Record<string, z.ZodType> } }).def.shape;
    const campo = forma.motivo_codigo;
    // optional(enum) — desce até o enum interno
    let atual: unknown = campo;
    for (let i = 0; i < 4; i += 1) {
      const def = (atual as { def?: { type?: string; innerType?: unknown; entries?: unknown } })?.def;
      if (def?.type === "enum" || def?.entries !== undefined) {
        const entries = def.entries ?? (def as { values?: unknown }).values;
        const valores = Array.isArray(entries)
          ? entries
          : entries && typeof entries === "object"
            ? Object.keys(entries as object)
            : [];
        expect(valores).toEqual(expect.arrayContaining(["requested_human", "critical_stage"]));
        return;
      }
      atual = def?.innerType ?? (atual as { _def?: { innerType?: unknown } })._def?.innerType;
      if (atual === undefined) break;
    }
    // Fallback: JSON Schema do Zod 4
    const js = z.toJSONSchema(campo as z.ZodType);
    const enumVals =
      (js as { enum?: string[] }).enum ??
      ((js as { anyOf?: Array<{ enum?: string[] }> }).anyOf ?? []).flatMap((a) => a.enum ?? []);
    expect(enumVals).toEqual(expect.arrayContaining(["requested_human", "critical_stage"]));
  });

  it("código inválido no enum do LARGO falha; a whitelist sozinha também — o runtime normaliza antes", () => {
    const payload = { motivo_codigo: "inventado" };
    expect(LARGO.safeParse(payload).success).toBe(false);
    expect(requestHumanHandoffInputSchema.safeParse(payload).success).toBe(false);
  });

  it("o modelo aprende as duas opções e quando NÃO usar etapa crítica", () => {
    const forma = (LARGO as unknown as { def: { shape: Record<string, z.ZodType> } }).def.shape;
    const descricao = forma.motivo_codigo?.description;
    expect(descricao).toContain("requested_human");
    expect(descricao).toContain("critical_stage");
    expect(descricao).toContain("Não use critical_stage só porque o cliente mencionou agendamento");
    expect(descricao).toMatch(/APENAS|requested_human.*critical_stage/i);
  });
});

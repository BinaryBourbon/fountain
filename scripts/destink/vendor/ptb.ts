// Penn-Treebank bracket parser. benepar (and most constituency parsers) emit parses as nested
// labelled brackets, e.g. (S (NP (DT the) (NN dog)) (VP (VBD barked) (ADVP (RB loudly)))).
// This turns that string into a Tree; src/lower.ts lowers a Tree into our Clause IR.

export type Tree = {
  label: string; // phrase/POS tag: S, NP, VP, DT, NN, VBD, ...
  word?: string; // set only on preterminals: (DT the) -> { label:"DT", word:"the" }
  children: Tree[];
};

export function parseBracket(input: string): Tree {
  const toks = input.replace(/\(/g, " ( ").replace(/\)/g, " ) ").trim().split(/\s+/);
  let i = 0;

  function node(): Tree {
    if (toks[i] !== "(") throw new Error(`PTB: expected '(' at token ${i}, got ${toks[i] ?? "EOF"}`);
    i++; // consume '('
    const label = toks[i++];
    if (label === undefined) throw new Error("PTB: missing label after '('");
    const children: Tree[] = [];
    let word: string | undefined;
    while (i < toks.length && toks[i] !== ")") {
      if (toks[i] === "(") children.push(node());
      else word = toks[i++]; // terminal word
    }
    if (toks[i] !== ")") throw new Error("PTB: unbalanced parentheses");
    i++; // consume ')'
    return word !== undefined ? { label, word, children } : { label, children };
  }

  const tree = node();
  // unwrap a ROOT/TOP/S1 wrapper if present
  return ["ROOT", "TOP", "S1", ""].includes(tree.label) && tree.children[0] ? tree.children[0]! : tree;
}

// All terminal words under a subtree, in order.
export const leaves = (t: Tree): string[] => (t.word !== undefined ? [t.word] : t.children.flatMap(leaves));
export const phrase = (t: Tree): string => leaves(t).join(" ");

// All (word, POS tag) preterminals under a subtree, in order — e.g. { word:"small", tag:"JJ" }.
// The parse keeps the fine POS the IR drops, so criteria like "two adjectives" read straight off it.
export const posTags = (t: Tree): Array<{ word: string; tag: string }> =>
  t.word !== undefined ? [{ word: t.word, tag: t.label }] : t.children.flatMap(posTags);

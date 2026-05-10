import { test, expect } from "bun:test";
import type { DomNode } from "../src/driver-protocol/types.ts";
import { normalizeSearchText, domNodeOutput } from "../src/commands/actions.ts";

function matchCandidates(elements: DomNode[], candidates?: string[]) {
  const matches: ReturnType<typeof domNodeOutput>[] = [];
  const matchedIndices = new Set<number>();
  for (const candidate of candidates ?? []) {
    const nc = normalizeSearchText(candidate);
    if (!nc) continue;
    for (let i = 0; i < elements.length; i++) {
      if (matchedIndices.has(i)) continue;
      const node = elements[i];
      const texts = [node.l, node.v]
        .filter((v): v is string => typeof v === "string" && v.trim().length > 0)
        .map((v) => normalizeSearchText(v));
      if (texts.some((v) => v.includes(nc))) {
        matchedIndices.add(i);
        matches.push(domNodeOutput(node));
      }
    }
  }
  return matches;
}

// ── Matching tests (no flattenDomNodes needed) ──

test("flat preorder: candidate matching works directly", () => {
  const flat: DomNode[] = [
    { tr: ["NavigationBar"], cc: 2 },
    { tr: ["Button"], l: "Back", r: [16, 54, 44, 44], cc: 0 },
    { tr: ["StaticText"], l: "Settings", r: [156, 54, 132, 44], cc: 0 },
    { tr: ["Button"], l: "Done", r: [350, 54, 30, 44], cc: 0 },
  ];
  const matches = matchCandidates(flat, ["Settings", "Back"]);
  expect(matches.length).toBe(2);
  expect(matches[0].label).toBe("Settings");
  expect(matches[1].label).toBe("Back");
});

test("flat preorder: no candidates returns empty", () => {
  const matches = matchCandidates([{ tr: ["Button"], l: "OK", r: [0, 0, 100, 44], cc: 0 }]);
  expect(matches.length).toBe(0);
});

test("flat preorder: unmatched candidate returns empty", () => {
  const matches = matchCandidates([{ tr: ["Button"], l: "OK", r: [0, 0, 100, 44], cc: 0 }], ["Nope"]);
  expect(matches.length).toBe(0);
});

test("flat preorder: matching against value field", () => {
  const flat: DomNode[] = [
    { tr: ["Switch"], v: "1", r: [340, 10, 50, 30], cc: 0 },
    { tr: ["StaticText"], l: "Wi-Fi", r: [10, 10, 50, 20], cc: 0 },
  ];
  const matches = matchCandidates(flat, ["1"]);
  expect(matches.length).toBe(1);
});

test("flat preorder: duplicate candidate only matches once", () => {
  const flat: DomNode[] = [
    { tr: ["StaticText"], l: "Wi-Fi", r: [10, 10, 50, 20], cc: 0 },
  ];
  const matches = matchCandidates(flat, ["Wi-Fi", "Wi-Fi"]);
  expect(matches.length).toBe(1);
});

// ── printDomFlatSubtree tests ──

function printDomFlatSubtree(elements: DomNode[], index: number, indent: string): number {
  const el = elements[index];
  const type = el.tr[0] || "?";
  const flags = el.tr.slice(1).join(",");
  const allTraits = flags ? `${type},${flags}` : type;
  const label = el.l?.trim();
  const value = el.v?.trim();
  let title: string;
  if (label) { title = value ? `${label}=${value}` : label; }
  else if (value) { title = `=${value}`; }
  else { title = type; }
  const flagStr = ` [${allTraits}]`;
  const isContainer = (el.cc ?? 0) > 0;

  if (isContainer) {
    console.log(`${indent}${title}${flagStr}:`);
    let childIdx = index + 1;
    for (let i = 0; i < (el.cc ?? 0); i++) {
      if (childIdx >= elements.length) break;
      childIdx = printDomFlatSubtree(elements, childIdx, indent + "  ");
    }
    return childIdx;
  }
  const rect = Array.isArray(el.r) ? ` (${el.r.join(",")})` : "";
  console.log(`${indent}- ${title}${flagStr}${rect}`);
  return index + 1;
}

test("printDomFlatSubtree: correct indentation and subtree consumption", () => {
  const flat: DomNode[] = [
    { tr: ["NavigationBar"], cc: 2 },
    { tr: ["Button"], l: "Back", r: [16, 54, 44, 44], cc: 0 },
    { tr: ["StaticText"], l: "Settings", r: [156, 54, 132, 44], cc: 0 },
    { tr: ["Table"], cc: 1 },
    { tr: ["Cell"], l: "Wi-Fi", cc: 1 },
    { tr: ["Switch"], v: "1", r: [340, 10, 50, 30], cc: 0 },
  ];

  const logs: string[] = [];
  const origLog = console.log;
  console.log = (...args: any[]) => { logs.push(args.join(" ")); };

  let idx = 0;
  while (idx < flat.length) {
    idx = printDomFlatSubtree(flat, idx, "  ");
  }

  console.log = origLog;
  expect(idx).toBe(6); // consumed all elements

  expect(logs).toEqual([
    "  NavigationBar [NavigationBar]:",
    "    - Back [Button] (16,54,44,44)",
    "    - Settings [StaticText] (156,54,132,44)",
    "  Table [Table]:",
    "    Wi-Fi [Cell]:",
    "      - =1 [Switch] (340,10,50,30)",
  ]);
});

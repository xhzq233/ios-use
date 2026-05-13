import { test, expect } from "bun:test";
import { parseFloatStrict, parseNonNegativeIntStrict, parseOffsetPair, parsePositiveIntStrict, parseSwipeDir } from "../src/commands/registry.ts";
import { normalizeSwipeDir } from "../src/commands/actions.ts";

test("parseFloatStrict rejects empty, whitespace, and non-decimal forms", () => {
  expect(() => parseFloatStrict("")).toThrow("Invalid number");
  expect(() => parseFloatStrict("   ")).toThrow("Invalid number");
  expect(() => parseFloatStrict("0x10")).toThrow("Invalid number");
});

test("parseFloatStrict accepts decimal forms", () => {
  expect(parseFloatStrict("1")).toBe(1);
  expect(parseFloatStrict("1.5")).toBe(1.5);
  expect(parseFloatStrict(".5")).toBe(0.5);
  expect(parseFloatStrict("-0.5")).toBe(-0.5);
});

test("parseSwipeDir and normalizeSwipeDir reject invalid direction", () => {
  expect(parseSwipeDir("forth")).toBe("forth");
  expect(parseSwipeDir("back")).toBe("back");
  expect(() => parseSwipeDir("forward")).toThrow("Invalid swipe dir");
  expect(normalizeSwipeDir(undefined)).toBe(-1);
  expect(normalizeSwipeDir("forth")).toBe(0);
  expect(normalizeSwipeDir("back")).toBe(1);
  expect(() => normalizeSwipeDir("forward")).toThrow("Invalid swipe dir");
});

test("parseOffsetPair rejects extra components", () => {
  expect(parseOffsetPair("10,")).toEqual({ x: 10, y: undefined });
  expect(parseOffsetPair(",20")).toEqual({ x: undefined, y: 20 });
  expect(() => parseOffsetPair("1,2,3")).toThrow("Invalid offset pair");
});

test("parseNonNegativeIntStrict rejects negative integers", () => {
  expect(parseNonNegativeIntStrict("0")).toBe(0);
  expect(parseNonNegativeIntStrict("1024")).toBe(1024);
  expect(() => parseNonNegativeIntStrict("-1")).toThrow("Invalid non-negative integer");
});

test("parsePositiveIntStrict rejects zero and negative integers", () => {
  expect(parsePositiveIntStrict("1")).toBe(1);
  expect(() => parsePositiveIntStrict("0")).toThrow("Invalid positive integer");
  expect(() => parsePositiveIntStrict("-1")).toThrow("Invalid positive integer");
});

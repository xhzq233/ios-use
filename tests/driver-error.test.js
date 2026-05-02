import { describe, test, expect } from 'bun:test';
import { formatDriverError } from '../src/utils/driverError.ts';

describe('formatDriverError', () => {
  test('expands matches suggestions and hint', () => {
    const error = Object.assign(new Error("label '天气' is ambiguous (2 matches)"), {
      data: {
        matches: [
          {
            ancestors: ['Application[com.apple.springboard]', 'Icon'],
            type: 'Icon',
            label: '天气',
            value: '多云',
            rect: [25, 65, 64, 87],
            traits: ['Icon'],
          },
          {
            ancestors: ['Application[com.apple.springboard]', 'Dock'],
            type: 'Icon',
            label: '天气',
            rect: [25, 170, 64, 87],
            traits: ['Icon', 'invisible'],
          },
        ],
        suggestions: ['使用 context.ancestorType=Icon'],
        hint: 'Try adding --context.ancestor-type / --context.ancestor-label',
      },
    });

    const formatted = formatDriverError(error);
    expect(formatted).toContain("label '天气' is ambiguous (2 matches)");
    expect(formatted).toContain('matches:');
    expect(formatted).toContain('Application[com.apple.springboard] > Icon');
    expect(formatted).toContain('Icon "天气=多云"');
    expect(formatted).toContain('Icon [invisible] "天气"');
    expect(formatted).toContain('suggestions: 使用 context.ancestorType=Icon');
    expect(formatted).toContain('hint: Try adding --context.ancestor-type / --context.ancestor-label');
  });
});

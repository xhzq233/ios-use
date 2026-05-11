type DriverMatch = {
  ancestors?: string[];
  type?: string;
  label?: string;
  value?: string;
  rect?: number[];
  traits?: string[];
};

type DriverErrorData = {
  matches?: DriverMatch[];
  suggestions?: string[];
  hint?: string;
};

function formatMatch(match: DriverMatch): string {
  const ancestors = Array.isArray(match.ancestors) ? match.ancestors.join(' > ') : '';
  const type = match.type || 'Unknown';
  const label = match.label || '';
  const display = match.value ? `${label}=${match.value}` : label;
  const rect = Array.isArray(match.rect) ? match.rect.join(',') : '';
  const flags = Array.isArray(match.traits) ? match.traits.slice(1).join(',') : '';
  const flagSuffix = flags ? ` [${flags}]` : '';
  return `  [${ancestors}] ${type}${flagSuffix} "${display}" (${rect})`;
}

export function formatDriverError(error: unknown): string {
  const err = error instanceof Error ? error : new Error(String(error ?? ''));
  const lines = [err.message];
  const data = (error as { data?: unknown })?.data as DriverErrorData | undefined;

  if (data?.matches?.length) {
    lines.push('matches:');
    for (const match of data.matches) {
      lines.push(formatMatch(match));
    }
  }
  if (data?.suggestions?.length) {
    lines.push(`suggestions: ${data.suggestions.join(', ')}`);
  }
  if (data?.hint) {
    lines.push(`hint: ${data.hint}`);
  }

  return lines.join('\n');
}

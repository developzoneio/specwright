// Title helpers from the first import tool. They predate the domain layer.

const _WHITESPACE = /\s+/g;

export function normalizeTitle(title) {
  return title.trim().replace(_WHITESPACE, ' ');
}

export function shortenTitle(title, max) {
  const clean = normalizeTitle(title);
  if (clean.length <= max) {
    return clean;
  }
  return clean.slice(0, max - 3) + '...';
}

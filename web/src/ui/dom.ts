type Child = Node | string | null | undefined | false;

export interface ElementOptions {
  className?: string;
  text?: string;
  attrs?: Record<string, string>;
  on?: Partial<Record<keyof HTMLElementEventMap, EventListener>>;
}

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, options: ElementOptions = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  if (options.className) element.className = options.className;
  if (options.text !== undefined) element.textContent = options.text;
  for (const [name, value] of Object.entries(options.attrs ?? {})) element.setAttribute(name, value);
  for (const [type, listener] of Object.entries(options.on ?? {})) {
    if (listener) element.addEventListener(type, listener);
  }
  for (const child of children) {
    if (child) element.append(child);
  }
  return element;
}

/** Inline SVG icon from path data (24 × 24 view box). */
export function icon(paths: readonly string[]): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('icon');
  for (const d of paths) {
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', d);
    svg.append(path);
  }
  return svg;
}

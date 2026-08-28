/**
 * A picture of the picked element.
 *
 * The browser has no API for "screenshot this element", so this is the SVG
 * `foreignObject` route: clone the element, carry enough computed style with it that
 * it still looks like itself, draw the SVG onto a canvas, and read the PNG out.
 *
 * It is best-effort by construction, and the format says so - `screenshotPNG` is an
 * optional field. Every one of these returns undefined rather than throwing:
 *
 * - a cross-origin image inside the element taints the canvas
 * - a custom font that is not same-origin will not load inside the SVG
 * - content inside a shadow root or an iframe does not clone
 *
 * The element reference and the trace still carry the annotation when it fails,
 * which is why a missing picture degrades quality and never correctness.
 */

/** The properties worth carrying. Inlining all ~340 computed properties per node
 *  makes the SVG enormous and the capture slow on anything but a tiny element. */
const CARRIED = [
  "background-color", "background-image", "background-position", "background-size",
  "border", "border-radius", "box-shadow", "box-sizing",
  "color", "display", "flex-direction", "align-items", "justify-content", "gap",
  "font-family", "font-size", "font-style", "font-weight", "letter-spacing",
  "line-height", "text-align", "text-decoration", "text-transform", "white-space",
  "margin", "padding", "opacity", "overflow", "vertical-align", "width", "height",
];

export interface CaptureOptions {
  /** Beyond this many elements the clone is skipped: a whole page is not a crop. */
  maxNodes?: number;
  /** Device pixel ratio to render at. */
  scale?: number;
}

export async function screenshotPNG(
  element: Element,
  options: CaptureOptions = {},
): Promise<string | undefined> {
  const { maxNodes = 400, scale = 2 } = options;
  const doc = element.ownerDocument;
  const view = doc.defaultView;
  if (!view || typeof view.getComputedStyle !== "function") return undefined;

  const box = element.getBoundingClientRect();
  if (box.width < 1 || box.height < 1) return undefined;
  if (element.querySelectorAll("*").length > maxNodes) return undefined;

  try {
    const clone = cloneWithStyle(element, doc, view);
    clone.setAttribute("style",
      `${clone.getAttribute("style") ?? ""};margin:0;position:static;` +
      `width:${box.width}px;height:${box.height}px;`);

    const serialised = new view.XMLSerializer().serializeToString(clone);
    const svg =
      `<svg xmlns="http://www.w3.org/2000/svg" width="${box.width}" height="${box.height}">` +
      `<foreignObject width="100%" height="100%">` +
      `<div xmlns="http://www.w3.org/1999/xhtml">${serialised}</div>` +
      `</foreignObject></svg>`;

    const image = await loadImage(
      `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`, view);

    const canvas = doc.createElement("canvas");
    canvas.width = Math.ceil(box.width * scale);
    canvas.height = Math.ceil(box.height * scale);
    const context = canvas.getContext("2d");
    if (!context) return undefined;
    context.scale(scale, scale);
    context.drawImage(image, 0, 0);

    // Base64 only, without the data URL prefix: that is what the bundle format
    // carries, and an agent reading it should not have to strip a header.
    return canvas.toDataURL("image/png").split(",")[1];
  } catch {
    return undefined;
  }
}

function cloneWithStyle(element: Element, doc: Document, view: Window): Element {
  const clone = element.cloneNode(true) as Element;
  const sources = [element, ...element.querySelectorAll("*")];
  const clones = [clone, ...clone.querySelectorAll("*")];

  for (let i = 0; i < sources.length && i < clones.length; i++) {
    const computed = view.getComputedStyle(sources[i]!);
    const declarations = CARRIED
      .map((property) => {
        const value = computed.getPropertyValue(property);
        return value ? `${property}:${value}` : "";
      })
      .filter(Boolean)
      .join(";");
    clones[i]!.setAttribute("style", declarations);
  }
  // Scripts inside a foreignObject never run, but shipping them into an image is
  // pointless weight either way.
  clone.querySelectorAll("script").forEach((s) => s.remove());
  return clone;
}

function loadImage(src: string, view: Window): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    // Built from the element's own window, not the global one: inside an iframe the
    // two are different realms and the global constructor is the wrong document's.
    const image = view.document.createElement("img");
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("the SVG would not load"));
    image.src = src;
  });
}

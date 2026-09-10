const fullTimestamp = /^(?:\d{1,3}:[0-5]\d:[0-5]\d|\d{1,3}:[0-5]\d)$/;

export function timestampToSeconds(value) {
  if (typeof value !== "string" || !fullTimestamp.test(value)) return null;
  return value.split(":").reduce((seconds, part) => seconds * 60 + Number(part), 0);
}

export function linkifyTimestampElement(element) {
  const text = element.textContent;
  const document = element.ownerDocument;
  let videoUrl;
  try {
    videoUrl = new URL(element.dataset.videoUrl);
    if (!["https:", "http:"].includes(videoUrl.protocol)) throw new Error("Unsupported URL");
  } catch {
    element.replaceChildren(document.createTextNode(text));
    return;
  }

  // Match the complete hour form first, and never link a prefix of an invalid clock.
  const pattern = /(^|\s)(\d{1,3}:[0-5]\d:[0-5]\d|\d{1,3}:[0-5]\d)(?![\d:A-Za-z]|\s*[AP]M\b)/gm;
  const fragment = document.createDocumentFragment();
  let cursor = 0;
  for (const match of text.matchAll(pattern)) {
    const start = match.index + match[1].length;
    const timestamp = match[2];
    const url = new URL(videoUrl.href);
    url.searchParams.set("t", `${timestampToSeconds(timestamp)}s`);
    const link = document.createElement("a");
    link.href = url.href;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.className = "clickable-timestamp";
    link.title = `Jump to ${timestamp}`;
    link.textContent = timestamp;
    fragment.append(document.createTextNode(text.slice(cursor, start)), link);
    cursor = start + timestamp.length;
  }
  fragment.append(document.createTextNode(text.slice(cursor)));
  element.replaceChildren(fragment);
}

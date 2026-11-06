export function getDragPosition(event: DragEvent): number | null {
  const element = event.currentTarget as HTMLElement;
  const bounds = element.getBoundingClientRect();
  const transform = getComputedStyle(element).transform;
  const offset =
    transform && transform !== "none" ? new DOMMatrix(transform) : null;
  // FLIP moves the card visually. Hit testing uses its final grid position.
  const left = bounds.left - (offset?.m41 || 0);
  const top = bounds.top - (offset?.m42 || 0);
  if (
    (bounds.width &&
      (event.clientX < left || event.clientX > left + bounds.width)) ||
    (bounds.height &&
      (event.clientY < top || event.clientY > top + bounds.height))
  )
    return null;
  return bounds.width ? (event.clientX - left) / bounds.width : 0.5;
}

export function reorderItems<T>(
  items: T[],
  moving: T[],
  target: T,
  placement: "before" | "after",
): T[] {
  const remaining = items.filter((item) => !moving.includes(item));
  const index = remaining.indexOf(target);
  if (index < 0) return items;
  remaining.splice(index + (placement === "after" ? 1 : 0), 0, ...moving);
  return remaining;
}

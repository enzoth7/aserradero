import { ArrowDown, ArrowUp, ChevronsUpDown } from "lucide-react";

export type SortDirection = "asc" | "desc";
export type SortState<K extends string> = { key: K; direction: SortDirection } | null;

/** Primer clic: orden inicial de la columna. Segundo clic: el inverso. Tercer clic: sin orden. */
export function nextSort<K extends string>(current: SortState<K>, key: K, first: SortDirection): SortState<K> {
  if (current?.key !== key) return { key, direction: first };
  if (current.direction === first) return { key, direction: first === "asc" ? "desc" : "asc" };
  return null;
}

/** Compara textos en español y números según la dirección; los vacíos van siempre al final. */
export function compareValues(a: string | number | null | undefined, b: string | number | null | undefined, direction: SortDirection) {
  const empty = (value: string | number | null | undefined) => value === null || value === undefined || value === "";
  if (empty(a) || empty(b)) return empty(a) === empty(b) ? 0 : empty(a) ? 1 : -1;
  const result = typeof a === "number" && typeof b === "number" ? a - b : String(a).localeCompare(String(b), "es", { numeric: true });
  return direction === "asc" ? result : -result;
}

/**
 * Encabezado que solo ordena. Las columnas numéricas arrancan de mayor a menor y las de texto de A a Z,
 * para que el mismo gesto signifique lo mismo en todas las tablas.
 */
export default function SortHeader<K extends string>({ label, sortKey, sort, onSort, numeric = false }: { label: string; sortKey: K; sort: SortState<K>; onSort: (next: SortState<K>) => void; numeric?: boolean }) {
  const first: SortDirection = numeric ? "desc" : "asc";
  const active = sort?.key === sortKey ? sort.direction : null;
  const names: Record<SortDirection, string> = numeric ? { desc: "de mayor a menor", asc: "de menor a mayor" } : { asc: "de A a Z", desc: "de Z a A" };
  const upcoming = nextSort(sort, sortKey, first);
  const hint = upcoming?.key === sortKey ? `Ordenar ${label} ${names[upcoming.direction]}` : `Quitar el orden por ${label}`;
  const Icon = active === "asc" ? ArrowUp : active === "desc" ? ArrowDown : ChevronsUpDown;
  return <button type="button" className={active ? "sort-header active" : "sort-header"} title={hint} aria-label={hint} aria-pressed={Boolean(active)} onClick={() => onSort(upcoming)}>
    <span>{label}</span>
    <Icon size={14} aria-hidden="true" />
  </button>;
}

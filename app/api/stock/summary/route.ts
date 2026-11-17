import { getStockSummary } from "../../store";

export async function GET(request: Request) {
  try {
    const includeOrderCommitments = new URL(request.url).searchParams.get("destinos") === "1";
    return Response.json({ stock: await getStockSummary(includeOrderCommitments) });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "No se pudo cargar el stock." }, { status: 500 });
  }
}

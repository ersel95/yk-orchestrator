"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, Moon } from "lucide-react";
import { api, cn } from "@/lib/utils";

type Health = { ok: boolean; llm: boolean; jira: boolean; bitbucket: boolean };

function Dot({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className="flex items-center gap-1.5 text-xs">
      <span className={cn("w-1.5 h-1.5 rounded-full", ok ? "bg-success" : "bg-danger")} />
      <span className="text-muted">{label}</span>
    </div>
  );
}

export function HealthBadge() {
  const qc = useQueryClient();
  const { data } = useQuery<Health>({
    queryKey: ["health"],
    queryFn: () => api<Health>("/health"),
    refetchInterval: 60_000,
  });

  const sleep = useMutation({
    mutationFn: () => api("/api/llm/sleep-all", { method: "POST" }),
    onSettled: () => qc.invalidateQueries({ queryKey: ["health"] }),
  });

  if (!data) {
    return <div className="text-xs text-muted">durum yükleniyor…</div>;
  }
  return (
    <div className="flex items-center gap-2">
      <button
        onClick={() => sleep.mutate()}
        disabled={!data.llm || sleep.isPending}
        title="LLM'i RAM'den boşalt (sonraki sorguda tekrar yüklenir)"
        className="flex items-center gap-1.5 px-2 py-1.5 rounded-md text-xs text-muted hover:text-text hover:bg-surface border border-border disabled:opacity-40"
      >
        {sleep.isPending ? <Loader2 size={12} className="animate-spin" /> : <Moon size={12} />}
        LLM'i Uyut
      </button>
      <div className="flex items-center gap-3 px-3 py-1.5 rounded-md bg-surface/60 border border-border">
        <Dot ok={data.llm} label="LLM" />
        <Dot ok={data.jira} label="Jira" />
        <Dot ok={data.bitbucket} label="Bitbucket" />
      </div>
    </div>
  );
}

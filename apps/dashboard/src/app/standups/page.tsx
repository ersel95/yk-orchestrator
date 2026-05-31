"use client";

import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import ReactMarkdown from "react-markdown";
import { Card, CardTitle, EmptyState, Badge } from "@/components/ui";
import { api } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";

type Standup = {
  id: number;
  standup_date: string;
  final_text: string;
  is_finalized: boolean;
};

export default function StandupHistoryPage() {
  const [selected, setSelected] = useState<string | null>(null);
  const project = useActiveProject();
  const projectId = project?.id;

  const list = useQuery({
    queryKey: ["standups", projectId],
    enabled: !!projectId,
    queryFn: () =>
      api<Standup[]>(`/api/standup/history?limit=60&project_id=${projectId}`),
  });

  const detail = useQuery({
    queryKey: ["standup", projectId, selected],
    queryFn: () =>
      api<Standup>(`/api/standup/by-date/${selected}?project_id=${projectId}`),
    enabled: !!selected && !!projectId,
  });

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold">Daily Geçmişi</h1>
        <p className="text-sm text-muted">Önceki günlerin daily metinleri.</p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        <Card className="lg:col-span-1">
          <CardTitle>Tarihler</CardTitle>
          {list.isLoading && <div className="text-sm text-muted">Yükleniyor…</div>}
          {list.data?.length === 0 && <EmptyState title="Henüz daily yok" />}
          <ul className="space-y-1">
            {list.data?.map((s) => (
              <li key={s.id}>
                <button
                  className={`w-full text-left px-3 py-2 rounded-md text-sm hover:bg-border/30 ${selected === s.standup_date ? "bg-border/40" : ""}`}
                  onClick={() => setSelected(s.standup_date)}
                >
                  <div className="flex items-center justify-between">
                    <span>{s.standup_date}</span>
                    {s.is_finalized && <Badge className="bg-success/20 text-success">✓</Badge>}
                  </div>
                </button>
              </li>
            ))}
          </ul>
        </Card>

        <Card className="lg:col-span-2">
          <CardTitle>Detay</CardTitle>
          {!selected && <EmptyState title="Sol listeden bir tarih seç" />}
          {detail.isLoading && <div className="text-sm text-muted">Yükleniyor…</div>}
          {detail.data && (
            <div className="prose prose-invert prose-sm max-w-none">
              <ReactMarkdown>{detail.data.final_text}</ReactMarkdown>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

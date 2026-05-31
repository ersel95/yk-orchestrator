"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Loader2, Upload } from "lucide-react";
import { Button, Card, CardTitle, EmptyState, Input, Textarea } from "@/components/ui";
import { api } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";

type TranscriptSummary = {
  id: number;
  meeting_date: string;
  title: string;
  created_at: string;
};

export default function TranscriptsPage() {
  const qc = useQueryClient();
  const today = new Date().toISOString().slice(0, 10);
  const [meetingDate, setMeetingDate] = useState(today);
  const [title, setTitle] = useState("Daily Standup");
  const [raw, setRaw] = useState("");
  const project = useActiveProject();
  const projectId = project?.id;

  const list = useQuery({
    queryKey: ["transcripts", projectId],
    enabled: !!projectId,
    queryFn: () =>
      api<TranscriptSummary[]>(`/api/transcript/list?limit=50&project_id=${projectId}`),
  });

  const ingest = useMutation({
    mutationFn: () =>
      api<any>("/api/transcript/ingest", {
        method: "POST",
        body: JSON.stringify({
          raw_text: raw,
          meeting_date: meetingDate,
          title,
          project_id: projectId,
        }),
      }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["transcripts"] });
      setRaw("");
    },
  });

  const [openId, setOpenId] = useState<number | null>(null);
  const detail = useQuery({
    queryKey: ["transcript", openId],
    queryFn: () => api<any>(`/api/transcript/${openId}`),
    enabled: !!openId,
  });

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold">Transkriptler</h1>
        <p className="text-sm text-muted">
          Daily konuşmasının metnini yapıştır — sistem konuşmacı bazlı özet ve aksiyon listesi çıkarır.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        <Card className="lg:col-span-2">
          <CardTitle>Yeni Transkript</CardTitle>
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-xs text-muted">Tarih</label>
                <Input type="date" value={meetingDate} onChange={(e) => setMeetingDate(e.target.value)} />
              </div>
              <div>
                <label className="text-xs text-muted">Başlık</label>
                <Input value={title} onChange={(e) => setTitle(e.target.value)} />
              </div>
            </div>
            <div>
              <label className="text-xs text-muted">Transkript metni</label>
              <Textarea
                placeholder={"Ersel: Dün API entegrasyonunu bitirdim, bugün test yazacağım.\nMurat: Backend tarafı hazır mı?\n..."}
                value={raw}
                onChange={(e) => setRaw(e.target.value)}
                rows={14}
              />
            </div>
            <Button onClick={() => ingest.mutate()} disabled={ingest.isPending || !raw.trim()}>
              {ingest.isPending ? <Loader2 className="animate-spin" size={14} /> : <Upload size={14} />}
              Yükle ve Analiz Et
            </Button>
            {ingest.data && (
              <div className="text-xs text-success">
                Eklendi: {ingest.data.utterance_count} konuşma parsed.
              </div>
            )}
          </div>
        </Card>

        <Card>
          <CardTitle>Geçmiş</CardTitle>
          {list.data?.length === 0 && <EmptyState title="Henüz transkript yok" />}
          <ul className="space-y-1">
            {list.data?.map((t) => (
              <li key={t.id}>
                <button
                  className={`w-full text-left px-3 py-2 rounded-md text-sm hover:bg-border/30 ${openId === t.id ? "bg-border/40" : ""}`}
                  onClick={() => setOpenId(t.id)}
                >
                  <div className="text-sm">{t.meeting_date}</div>
                  <div className="text-xs text-muted">{t.title}</div>
                </button>
              </li>
            ))}
          </ul>
        </Card>
      </div>

      {openId && detail.data && (
        <Card>
          <CardTitle>{detail.data.transcript.meeting_date} — {detail.data.transcript.title}</CardTitle>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <div className="text-xs uppercase text-muted mb-1">Konuşmacılar</div>
              <pre className="text-xs whitespace-pre-wrap font-mono bg-bg p-3 rounded">
                {detail.data.transcript.summary || "(yok)"}
              </pre>
            </div>
            <div>
              <div className="text-xs uppercase text-muted mb-1">Aksiyon / Karar / Blocker</div>
              <pre className="text-xs whitespace-pre-wrap font-mono bg-bg p-3 rounded">
                {detail.data.transcript.action_items || "(yok)"}
              </pre>
            </div>
          </div>
          <div className="mt-4">
            <div className="text-xs uppercase text-muted mb-1">Konuşmalar</div>
            <div className="space-y-2 max-h-72 overflow-y-auto scrollbar-thin">
              {detail.data.utterances.map((u: any) => (
                <div key={u.id} className="text-sm">
                  <span className="text-accent font-medium">{u.speaker}:</span>{" "}
                  <span className="text-muted">{u.text}</span>
                </div>
              ))}
            </div>
          </div>
        </Card>
      )}
    </div>
  );
}

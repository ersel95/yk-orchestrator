"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import ReactMarkdown from "react-markdown";
import { Loader2, RefreshCw, Save, Sparkles } from "lucide-react";
import { Button, Card, CardTitle, EmptyState, Textarea, Badge } from "@/components/ui";
import { api } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";

type StandupResult = {
  date: string;
  text: string;
  yesterday: string;
  today: string;
  blockers: string;
  source_data: {
    jira_done: any[];
    merged_prs: any[];
    commits: any[];
    open_issues: any[];
  };
  errors: string[];
};

export default function TodayPage() {
  const qc = useQueryClient();
  const today = new Date().toISOString().slice(0, 10);
  const [blockers, setBlockers] = useState("");
  const [edited, setEdited] = useState<string | null>(null);
  const project = useActiveProject();
  const projectId = project?.id;

  const cached = useQuery({
    queryKey: ["standup", projectId, today],
    enabled: !!projectId,
    queryFn: async () => {
      try {
        return await api<any>(`/api/standup/by-date/${today}?project_id=${projectId}`);
      } catch {
        return null;
      }
    },
  });

  const generate = useMutation({
    mutationFn: async () =>
      api<StandupResult>("/api/standup/generate", {
        method: "POST",
        body: JSON.stringify({ for_date: today, blockers, project_id: projectId }),
      }),
    onSuccess: (data) => {
      setEdited(data.text);
      qc.setQueryData(["standup", projectId, today], data);
    },
  });

  const finalize = useMutation({
    mutationFn: async () =>
      api(`/api/standup/finalize`, {
        method: "POST",
        body: JSON.stringify({ for_date: today, text: edited || "", project_id: projectId }),
      }),
  });

  const data: any = generate.data || cached.data;

  useEffect(() => {
    if (cached.data?.final_text && edited === null) setEdited(cached.data.final_text);
  }, [cached.data, edited]);

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">
            Bugün ({today}){" "}
            {project && (
              <span className="text-muted text-sm font-normal">— {project.name}</span>
            )}
          </h1>
          <p className="text-sm text-muted">
            Daily standup metnini otomatik üret, düzenle, kaydet.
          </p>
        </div>
        <div className="flex gap-2">
          <Button
            variant="ghost"
            onClick={() => generate.mutate()}
            disabled={generate.isPending}
          >
            {generate.isPending ? <Loader2 className="animate-spin" size={14} /> : <RefreshCw size={14} />}
            Veriyi Çek + Üret
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        <Card className="lg:col-span-2">
          <CardTitle>
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-2"><Sparkles size={14} className="text-accent" /> Daily Metni</span>
              {data?.is_finalized && <Badge className="bg-success/20 text-success">Kaydedildi</Badge>}
            </div>
          </CardTitle>
          {!data && !generate.isPending && (
            <EmptyState
              title="Henüz daily üretilmedi"
              hint="Sağ üstteki 'Veriyi Çek + Üret' butonuna bas. Sistem Jira'dan açık işlerini, dünkü merge'lerini ve commit'lerini toplar, LLM ile metni hazırlar."
            />
          )}
          {generate.isPending && (
            <div className="flex items-center gap-2 text-sm text-muted py-8 justify-center">
              <Loader2 className="animate-spin" size={14} /> Lokal LLM çalışıyor — bu 30 saniye kadar sürebilir
            </div>
          )}
          {data && (
            <>
              <Textarea
                value={edited ?? data.final_text ?? data.text ?? ""}
                onChange={(e) => setEdited(e.target.value)}
                rows={14}
              />
              <div className="flex items-center justify-between mt-3">
                <div className="text-xs text-muted">
                  Düzenleyebilirsin. Aşağıdaki kaynak verilere göre üretildi.
                </div>
                <Button onClick={() => finalize.mutate()} disabled={finalize.isPending}>
                  <Save size={14} /> Kaydet
                </Button>
              </div>
              {finalize.isSuccess && (
                <div className="text-xs text-success mt-2">Daily kaydedildi.</div>
              )}
            </>
          )}
        </Card>

        <div className="space-y-5">
          <Card>
            <CardTitle>Blocker (opsiyonel)</CardTitle>
            <Textarea
              placeholder="Bekleyen onay, bağımlılık, vs."
              value={blockers}
              onChange={(e) => setBlockers(e.target.value)}
              rows={4}
            />
          </Card>

          <Card>
            <CardTitle>Dün Yapılanlar</CardTitle>
            <pre className="text-xs whitespace-pre-wrap text-muted font-mono">
              {data?.yesterday || data?.yesterday_summary || "(üretilmedi)"}
            </pre>
          </Card>

          <Card>
            <CardTitle>Bugün Açık İşler</CardTitle>
            <pre className="text-xs whitespace-pre-wrap text-muted font-mono">
              {data?.today || data?.today_plan || "(üretilmedi)"}
            </pre>
          </Card>

          {data?.errors?.length > 0 && (
            <Card>
              <CardTitle>Uyarılar</CardTitle>
              <ul className="text-xs text-warn space-y-1">
                {data.errors.map((e: string, i: number) => (
                  <li key={i}>• {e}</li>
                ))}
              </ul>
            </Card>
          )}
        </div>
      </div>

      {data?.text && (
        <Card>
          <CardTitle>Önizleme</CardTitle>
          <div className="prose prose-invert prose-sm max-w-none">
            <ReactMarkdown>{edited ?? data.text}</ReactMarkdown>
          </div>
        </Card>
      )}
    </div>
  );
}

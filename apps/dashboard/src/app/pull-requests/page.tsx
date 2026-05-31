"use client";

import { useMutation, useQuery } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import {
  AlertTriangle,
  Check,
  ExternalLink,
  FileCode,
  GitPullRequest,
  Info,
  Loader2,
  MessageSquare,
  RefreshCw,
  Send,
  Sparkles,
  ThumbsUp,
  X,
} from "lucide-react";
import ReactMarkdown from "react-markdown";
import { Badge, Button, Card, CardTitle, EmptyState, Input, Textarea } from "@/components/ui";
import { api, API_BASE, cn } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";
import {
  BitbucketDiffResponse,
  ChangeItem,
  CommentDeleteSubmit,
  CommentEditSubmit,
  DiffViewer,
  ExistingComment,
  FileList,
  LineCommentSubmit,
} from "@/components/DiffViewer";
import { useQueryClient } from "@tanstack/react-query";

type Reviewer = {
  name: string;
  display_name: string;
  status: "APPROVED" | "NEEDS_WORK" | "UNAPPROVED";
  approved: boolean;
};

type PR = {
  pr_id: string;
  repo: string;
  number: number;
  title: string;
  author: string;
  author_display?: string;
  source_branch: string;
  target_branch: string;
  is_mine: boolean;
  needs_my_review: boolean;
  state: string;
  url: string;
  my_status?: "APPROVED" | "NEEDS_WORK" | "UNAPPROVED" | null;
  approved_count?: number;
  needs_work_count?: number;
  reviewers?: Reviewer[];
};

export default function PullRequestsPage() {
  const [tab, setTab] = useState<"open" | "review" | "draft">("review");
  const project = useActiveProject();
  const projectId = project?.id;

  const reviewQuery = useQuery({
    queryKey: ["prs", "review", projectId],
    enabled: !!projectId,
    queryFn: () => api<PR[]>(`/api/pr/review?project_id=${projectId}`),
  });

  const [draftBranch, setDraftBranch] = useState("");
  const [draftTarget, setDraftTarget] = useState(project?.git_default_branch || "develop");
  const [draftPreview, setDraftPreview] = useState<any>(null);
  const [editTitle, setEditTitle] = useState("");
  const [editDesc, setEditDesc] = useState("");

  const draft = useMutation({
    mutationFn: () =>
      api<any>("/api/pr/draft", {
        method: "POST",
        body: JSON.stringify({
          source_branch: draftBranch,
          target_branch: draftTarget,
          project_id: projectId,
        }),
      }),
    onSuccess: (data) => {
      setDraftPreview(data);
      setEditTitle(data.title_suggestion || "");
      setEditDesc(data.description || "");
    },
  });

  const openPR = useMutation({
    mutationFn: () =>
      api<any>("/api/pr/open", {
        method: "POST",
        body: JSON.stringify({
          title: editTitle,
          description: editDesc,
          source_branch: draftBranch,
          target_branch: draftTarget,
          project_id: projectId,
        }),
      }),
  });

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold">Pull Request'ler</h1>
        <p className="text-sm text-muted">Aç, review et, takip et.</p>
      </div>

      <div className="flex gap-2 border-b border-border">
        {[
          { k: "review", label: "Review Bekleyen" },
          { k: "open", label: "Benimkiler" },
          { k: "draft", label: "Yeni PR Aç" },
        ].map((t) => (
          <button
            key={t.k}
            onClick={() => setTab(t.k as any)}
            className={cn(
              "px-3 py-2 text-sm border-b-2 -mb-px",
              tab === t.k ? "border-accent text-accent" : "border-transparent text-muted hover:text-text"
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "review" && (
        <div className="space-y-3">
          <div className="flex justify-end">
            <Button variant="ghost" onClick={() => reviewQuery.refetch()}>
              <RefreshCw size={14} /> Yenile
            </Button>
          </div>
          {reviewQuery.isLoading && <div className="text-sm text-muted">Yükleniyor…</div>}
          {reviewQuery.data?.length === 0 && (
            <EmptyState title="Bekleyen PR yok" hint="Bitbucket'ta sana atanmış PR yok." />
          )}
          {reviewQuery.data?.map((pr) => (
            <PRCard key={pr.pr_id} pr={pr} />
          ))}
        </div>
      )}

      {tab === "open" && (
        <div className="space-y-3">
          {reviewQuery.data?.filter((p) => p.is_mine).map((pr) => <PRCard key={pr.pr_id} pr={pr} />)}
          {(reviewQuery.data?.filter((p) => p.is_mine) ?? []).length === 0 && (
            <EmptyState title="Açık PR'ın yok" />
          )}
        </div>
      )}

      {tab === "draft" && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-5">
          <Card>
            <CardTitle>Yeni PR Hazırlığı</CardTitle>
            <div className="space-y-3">
              <div>
                <label className="text-xs text-muted">Source branch</label>
                <Input value={draftBranch} onChange={(e) => setDraftBranch(e.target.value)} placeholder="feature/IOS-1234" />
              </div>
              <div>
                <label className="text-xs text-muted">Target branch</label>
                <Input value={draftTarget} onChange={(e) => setDraftTarget(e.target.value)} />
              </div>
              <Button onClick={() => draft.mutate()} disabled={draft.isPending || !draftBranch}>
                {draft.isPending ? <Loader2 className="animate-spin" size={14} /> : <Sparkles size={14} />}
                Diff'ten Açıklama Üret
              </Button>
            </div>
          </Card>
          <Card>
            <CardTitle>Önizle ve Aç</CardTitle>
            {!draftPreview && <EmptyState title="Önce 'Açıklama Üret'e bas" />}
            {draftPreview && (
              <div className="space-y-3">
                <div>
                  <label className="text-xs text-muted">Başlık</label>
                  <Input value={editTitle} onChange={(e) => setEditTitle(e.target.value)} />
                </div>
                <div>
                  <label className="text-xs text-muted">Açıklama (Markdown)</label>
                  <Textarea value={editDesc} onChange={(e) => setEditDesc(e.target.value)} rows={14} />
                </div>
                <Button onClick={() => openPR.mutate()} disabled={openPR.isPending}>
                  {openPR.isPending ? <Loader2 className="animate-spin" size={14} /> : <Send size={14} />}
                  PR'ı Bitbucket'ta Aç
                </Button>
                {openPR.isSuccess && <div className="text-xs text-success">PR açıldı.</div>}
                {openPR.isError && <div className="text-xs text-danger">{(openPR.error as Error).message}</div>}
              </div>
            )}
          </Card>
        </div>
      )}
    </div>
  );
}

function PRCard({ pr }: { pr: PR }) {
  const [open, setOpen] = useState(false);
  const [activePanel, setActivePanel] = useState<"summary" | "files" | "ai" | "comment">("summary");
  const project = useActiveProject();
  const projectId = project?.id;
  const qc = useQueryClient();

  const setStatus = useMutation({
    mutationFn: (status: "APPROVED" | "NEEDS_WORK" | "UNAPPROVED") =>
      api<any>(`/api/pr/review/${pr.repo}/${pr.number}/status`, {
        method: "POST",
        body: JSON.stringify({ status, project_id: projectId }),
      }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["prs", "review", projectId] });
    },
    onError: (err) => {
      // PR artık güncellenemiyorsa (merge/kapanmış → API 409) listeyi tazele.
      const msg = (err as Error).message || "";
      if (msg.startsWith("API 409")) {
        qc.invalidateQueries({ queryKey: ["prs", "review", projectId] });
      }
    },
  });

  return (
    <Card>
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <GitPullRequest size={14} className="text-accent shrink-0" />
            <a
              href={pr.url}
              target="_blank"
              className="font-medium hover:text-accent text-sm flex items-center gap-1"
              rel="noreferrer"
            >
              {pr.title}
              <ExternalLink size={11} className="text-muted" />
            </a>
            {pr.is_mine && <Badge className="bg-accent/20 text-accent">Benim</Badge>}
            {pr.my_status === "APPROVED" && (
              <Badge className="bg-success/20 text-success">
                <ThumbsUp size={10} className="mr-1" /> Sen approve ettin
              </Badge>
            )}
            {pr.my_status === "NEEDS_WORK" && (
              <Badge className="bg-warn/20 text-warn">
                <AlertTriangle size={10} className="mr-1" /> Senden değişiklik bekleniyor
              </Badge>
            )}
            {pr.my_status === "UNAPPROVED" && pr.needs_my_review && (
              <Badge className="bg-warn/20 text-warn">Review bekliyor</Badge>
            )}
            {(pr.approved_count ?? 0) > 0 && (
              <Badge className="bg-success/15 text-success">
                ✓ {pr.approved_count} approved
              </Badge>
            )}
            {(pr.needs_work_count ?? 0) > 0 && (
              <Badge className="bg-warn/15 text-warn">
                ⚠ {pr.needs_work_count} needs work
              </Badge>
            )}
            <Badge>{pr.state}</Badge>
          </div>
          <div className="text-xs text-muted mt-1">
            {pr.author_display || pr.author} · {pr.source_branch} → {pr.target_branch} · #{pr.number} · {pr.repo}
          </div>
          {pr.reviewers && pr.reviewers.length > 0 && (
            <div className="text-[11px] text-muted mt-1.5 flex flex-wrap gap-1.5">
              {pr.reviewers.map((r) => (
                <span
                  key={r.name}
                  className={cn(
                    "inline-flex items-center gap-1 px-1.5 py-0.5 rounded",
                    r.status === "APPROVED"
                      ? "bg-success/10 text-success"
                      : r.status === "NEEDS_WORK"
                        ? "bg-warn/10 text-warn"
                        : "bg-border/40 text-muted"
                  )}
                  title={`${r.display_name}: ${r.status}`}
                >
                  {r.status === "APPROVED" ? "✓" : r.status === "NEEDS_WORK" ? "⚠" : "○"}{" "}
                  {r.display_name}
                </span>
              ))}
            </div>
          )}
        </div>
        <Button
          variant="ghost"
          onClick={() => setOpen(!open)}
        >
          {open ? <X size={14} /> : <Sparkles size={14} />}
          {open ? "Kapat" : "Detay"}
        </Button>
      </div>

      {open && (
        <div className="mt-3 pt-3 border-t border-border space-y-3">
          {/* Action bar — aktif state'i vurgula */}
          <div className="flex flex-wrap items-center gap-2">
            <Button
              onClick={() => setStatus.mutate("APPROVED")}
              disabled={setStatus.isPending}
              className={cn(
                "border",
                pr.my_status === "APPROVED"
                  ? "bg-success text-bg border-success ring-2 ring-success/40"
                  : "bg-success/20 text-success hover:bg-success/30 border-success/30"
              )}
            >
              <ThumbsUp size={14} />
              {pr.my_status === "APPROVED" ? "Approved ✓" : "Approve"}
            </Button>
            <Button
              onClick={() => setStatus.mutate("NEEDS_WORK")}
              disabled={setStatus.isPending}
              variant="ghost"
              className={cn(
                "border",
                pr.my_status === "NEEDS_WORK"
                  ? "bg-warn text-bg border-warn ring-2 ring-warn/40"
                  : "border-warn/40 text-warn hover:bg-warn/10"
              )}
            >
              <AlertTriangle size={14} />
              {pr.my_status === "NEEDS_WORK" ? "Needs Work ✓" : "Needs Work"}
            </Button>
            {pr.my_status && pr.my_status !== "UNAPPROVED" && (
              <Button
                onClick={() => setStatus.mutate("UNAPPROVED")}
                disabled={setStatus.isPending}
                variant="ghost"
              >
                Geri al
              </Button>
            )}
            {setStatus.isPending && (
              <span className="text-xs text-muted flex items-center gap-1">
                <Loader2 size={12} className="animate-spin" /> Bitbucket'a yazılıyor…
              </span>
            )}
            {setStatus.isError && (
              <span className="text-xs text-danger">{prettyApiError(setStatus.error as Error)}</span>
            )}
          </div>

          {/* Tabs */}
          <div className="flex gap-1 text-xs border-b border-border">
            {[
              { k: "summary", label: "AI Özet", icon: Sparkles },
              { k: "files", label: "Dosyalar / Diff", icon: FileCode },
              { k: "ai", label: "AI Yorum Önerileri", icon: Sparkles },
              { k: "comment", label: "Yorum Yaz", icon: MessageSquare },
            ].map((t) => (
              <button
                key={t.k}
                onClick={() => setActivePanel(t.k as any)}
                className={cn(
                  "flex items-center gap-1 px-3 py-1.5 -mb-px border-b-2",
                  activePanel === t.k
                    ? "border-accent text-accent"
                    : "border-transparent text-muted hover:text-text"
                )}
              >
                <t.icon size={11} />
                {t.label}
              </button>
            ))}
          </div>

          {activePanel === "summary" && <SummaryPanel pr={pr} />}
          {activePanel === "files" && <FilesPanel pr={pr} />}
          {activePanel === "ai" && <AISuggestionsPanel pr={pr} />}
          {activePanel === "comment" && <CommentPanel pr={pr} />}
        </div>
      )}
    </Card>
  );
}

function SummaryPanel({ pr }: { pr: PR }) {
  const project = useActiveProject();
  const projectId = project?.id;
  const [text, setText] = useState("");
  const [running, setRunning] = useState(false);
  const [meta, setMeta] = useState<any>(null);
  const [elapsed, setElapsed] = useState(0);
  const [ttft, setTtft] = useState<number | null>(null);
  const esRef = useRef<EventSource | null>(null);

  function start() {
    if (running) return;
    setText("");
    setMeta(null);
    setTtft(null);
    setElapsed(0);
    setRunning(true);
    const t0 = performance.now();
    const url = `${API_BASE}/api/pr/review/${pr.repo}/${pr.number}/summary/stream?project_id=${projectId}`;
    const es = new EventSource(url);
    esRef.current = es;

    const tick = setInterval(() => {
      setElapsed((performance.now() - t0) / 1000);
    }, 200);

    es.addEventListener("meta", (e: MessageEvent) => {
      try { setMeta(JSON.parse(e.data)); } catch {}
    });
    es.addEventListener("delta", (e: MessageEvent) => {
      try {
        if (ttft == null) setTtft((performance.now() - t0) / 1000);
        const chunk = JSON.parse(e.data);
        if (typeof chunk === "string") setText((t) => t + chunk);
      } catch {}
    });
    es.addEventListener("done", () => {
      clearInterval(tick);
      es.close();
      esRef.current = null;
      setRunning(false);
    });
    es.addEventListener("error", () => {
      clearInterval(tick);
      es.close();
      esRef.current = null;
      setRunning(false);
    });
  }

  useEffect(() => {
    return () => { esRef.current?.close(); };
  }, []);

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <Button onClick={start} disabled={running}>
          {running ? <Loader2 className="animate-spin" size={14} /> : <Sparkles size={14} />}
          {text ? "Tekrar üret" : "AI Özet Üret"}
        </Button>
        {(running || text) && (
          <div className="text-xs text-muted font-mono flex gap-3">
            <span>⏱ {elapsed.toFixed(1)}s</span>
            {ttft != null && <span>ttft {ttft.toFixed(1)}s</span>}
            {meta?.diff_stat && <span>{meta.diff_stat}</span>}
          </div>
        )}
      </div>
      {!running && !text && (
        <div className="text-xs text-muted">
          Tıklayınca tech-lead pre-review raporu üretilir (özet + risk haritası + dikkat noktaları).
        </div>
      )}
      {(running || text) && (
        <div className="prose prose-invert prose-sm max-w-none">
          <ReactMarkdown>{text || "_yazıyor…_"}</ReactMarkdown>
        </div>
      )}
    </div>
  );
}

function FilesPanel({ pr }: { pr: PR }) {
  const project = useActiveProject();
  const projectId = project?.id;
  const qc = useQueryClient();

  const changes = useQuery({
    queryKey: ["pr-changes", pr.pr_id],
    queryFn: () =>
      api<ChangeItem[]>(
        `/api/pr/review/${pr.repo}/${pr.number}/changes?project_id=${projectId}`
      ),
  });

  const [selectedPath, setSelectedPath] = useState<string | null>(null);

  // İlk dosyayı otomatik seç
  if (!selectedPath && changes.data && changes.data.length > 0) {
    setSelectedPath(changes.data[0].path);
  }

  const fileDiff = useQuery({
    queryKey: ["pr-file-diff", pr.pr_id, selectedPath],
    enabled: !!selectedPath,
    queryFn: () =>
      api<{ path: string; diff: BitbucketDiffResponse }>(
        `/api/pr/review/${pr.repo}/${pr.number}/file-diff?project_id=${projectId}&path=${encodeURIComponent(selectedPath || "")}&context_lines=10`
      ),
  });

  const fileComments = useQuery({
    queryKey: ["pr-file-comments", pr.pr_id, selectedPath],
    enabled: !!selectedPath,
    queryFn: () =>
      api<ExistingComment[]>(
        `/api/pr/review/${pr.repo}/${pr.number}/file-comments?project_id=${projectId}&path=${encodeURIComponent(selectedPath || "")}`
      ),
  });

  function invalidateComments() {
    qc.invalidateQueries({ queryKey: ["pr-file-comments", pr.pr_id, selectedPath] });
  }

  const handleAddComment: LineCommentSubmit = async ({ path, line, lineType, text }) => {
    await api(`/api/pr/review/${pr.repo}/${pr.number}/comment`, {
      method: "POST",
      body: JSON.stringify({
        text,
        project_id: projectId,
        anchor: {
          line,
          lineType,
          fileType: lineType === "REMOVED" ? "FROM" : "TO",
          path,
          diffType: "EFFECTIVE",
        },
      }),
    });
    invalidateComments();
  };

  const handleEditComment: CommentEditSubmit = async ({ id, version, text }) => {
    await api(`/api/pr/review/${pr.repo}/${pr.number}/comment/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ text, version, project_id: projectId }),
    });
    invalidateComments();
  };

  const handleDeleteComment: CommentDeleteSubmit = async ({ id, version }) => {
    await api(
      `/api/pr/review/${pr.repo}/${pr.number}/comment/${id}?version=${version}&project_id=${projectId}`,
      { method: "DELETE" }
    );
    invalidateComments();
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-[300px_1fr] gap-0 border border-border rounded-md overflow-hidden bg-surface/30">
      <div className="border-r border-border max-h-[70vh] flex flex-col">
        {changes.isLoading && (
          <div className="p-3 text-xs text-muted">Dosya listesi yükleniyor…</div>
        )}
        {changes.data && (
          <FileList
            changes={changes.data}
            selected={selectedPath}
            onSelect={setSelectedPath}
          />
        )}
      </div>
      <div className="max-h-[70vh] overflow-auto scrollbar-thin">
        {!selectedPath && (
          <div className="p-4 text-xs text-muted">Bir dosya seç</div>
        )}
        {selectedPath && fileDiff.isLoading && (
          <div className="p-4 text-xs text-muted">Diff yükleniyor…</div>
        )}
        {fileDiff.data && (
          <div className="p-3">
            <DiffViewer
              data={fileDiff.data.diff}
              filePath={fileDiff.data.path}
              comments={fileComments.data}
              onAddComment={handleAddComment}
              onEditComment={handleEditComment}
              onDeleteComment={handleDeleteComment}
            />
          </div>
        )}
      </div>
    </div>
  );
}

type Suggestion = {
  path: string;
  line: number;
  line_type?: string;
  severity: "info" | "warning" | "critical";
  title: string;
  comment: string;
  suggestion?: string;
};

function AISuggestionsPanel({ pr }: { pr: PR }) {
  const project = useActiveProject();
  const projectId = project?.id;
  const [items, setItems] = useState<Suggestion[]>([]);
  const [selected, setSelected] = useState<Set<number>>(new Set());

  const generate = useMutation({
    mutationFn: () =>
      api<any>(`/api/pr/review/${pr.repo}/${pr.number}/ai-suggestions?project_id=${projectId}`, {
        method: "POST",
      }),
    onSuccess: (data) => {
      setItems(data.suggestions || []);
      setSelected(new Set((data.suggestions || []).map((_: any, i: number) => i)));
    },
  });

  const post = useMutation({
    mutationFn: () => {
      const chosen = items.filter((_, i) => selected.has(i));
      return api<any>(`/api/pr/review/${pr.repo}/${pr.number}/ai-suggestions/post`, {
        method: "POST",
        body: JSON.stringify({ suggestions: chosen, project_id: projectId }),
      });
    },
  });

  function toggle(i: number) {
    setSelected((s) => {
      const c = new Set(s);
      if (c.has(i)) c.delete(i);
      else c.add(i);
      return c;
    });
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="text-xs text-muted">
          AI, diff'i okuyup inline yorum önerileri çıkarır. Beğendiklerini seçip Bitbucket'a gönder.
        </div>
        <Button
          onClick={() => generate.mutate()}
          disabled={generate.isPending}
        >
          {generate.isPending ? <Loader2 className="animate-spin" size={14} /> : <Sparkles size={14} />}
          {items.length > 0 ? "Tekrar üret" : "Öneri Üret"}
        </Button>
      </div>
      {generate.isPending && (
        <div className="text-sm text-muted">Qwen diff'i analiz ediyor (30-60 sn)…</div>
      )}
      {generate.data && items.length === 0 && (
        <EmptyState title="AI yorum önermedi" hint="Diff'te önemli bir nokta görmemiş olabilir." />
      )}
      {items.map((s, i) => (
        <div
          key={i}
          className={cn(
            "border rounded p-3 cursor-pointer transition-colors",
            selected.has(i) ? "border-accent/60 bg-accent/5" : "border-border bg-surface/40"
          )}
          onClick={() => toggle(i)}
        >
          <div className="flex items-start gap-2">
            <input
              type="checkbox"
              checked={selected.has(i)}
              onChange={() => toggle(i)}
              onClick={(e) => e.stopPropagation()}
              className="mt-1"
            />
            <div className="flex-1">
              <div className="flex items-center gap-2 flex-wrap">
                <SeverityBadge severity={s.severity} />
                <span className="text-sm font-medium">{s.title}</span>
                <span className="text-[11px] text-muted font-mono">
                  {s.path}:{s.line}
                </span>
              </div>
              <div className="text-sm text-muted mt-1">{s.comment}</div>
              {s.suggestion && (
                <pre className="text-[11px] font-mono bg-bg p-2 rounded mt-2 overflow-x-auto scrollbar-thin">
                  {s.suggestion}
                </pre>
              )}
            </div>
          </div>
        </div>
      ))}
      {items.length > 0 && (
        <div className="flex items-center justify-end gap-2">
          <span className="text-xs text-muted">{selected.size} / {items.length} seçili</span>
          <Button onClick={() => post.mutate()} disabled={post.isPending || selected.size === 0}>
            {post.isPending ? <Loader2 className="animate-spin" size={14} /> : <Send size={14} />}
            Seçilenleri Bitbucket'a Gönder
          </Button>
        </div>
      )}
      {post.isSuccess && (
        <div className="text-xs text-success">
          ✓ {(post.data as any)?.posted} yorum gönderildi.
        </div>
      )}
      {post.isError && (
        <div className="text-xs text-danger">{(post.error as Error).message}</div>
      )}
    </div>
  );
}

function SeverityBadge({ severity }: { severity: string }) {
  const map: Record<string, { cls: string; icon: any; label: string }> = {
    info: { cls: "bg-accent/20 text-accent", icon: Info, label: "info" },
    warning: { cls: "bg-warn/20 text-warn", icon: AlertTriangle, label: "warning" },
    critical: { cls: "bg-danger/20 text-danger", icon: AlertTriangle, label: "critical" },
  };
  const m = map[severity] || map.info;
  const Icon = m.icon;
  return (
    <span className={cn("inline-flex items-center gap-1 px-1.5 py-0.5 text-[10px] rounded", m.cls)}>
      <Icon size={10} />
      {m.label}
    </span>
  );
}

function prettyApiError(err: Error): string {
  const m = err.message.match(/^API \d+:\s*(.*)$/s);
  if (!m) return err.message;
  try {
    const body = JSON.parse(m[1]);
    if (typeof body?.detail === "string") return body.detail;
  } catch {}
  return m[1];
}

function CommentPanel({ pr }: { pr: PR }) {
  const project = useActiveProject();
  const projectId = project?.id;
  const [text, setText] = useState("");
  const post = useMutation({
    mutationFn: () =>
      api<any>(`/api/pr/review/${pr.repo}/${pr.number}/comment`, {
        method: "POST",
        body: JSON.stringify({ text, project_id: projectId }),
      }),
    onSuccess: () => setText(""),
  });
  return (
    <div className="space-y-2">
      <Textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        rows={4}
        placeholder="Manuel yorum (genel PR yorumu)…"
      />
      <div className="flex items-center justify-end gap-2">
        {post.isSuccess && <span className="text-xs text-success">✓ Yorum eklendi</span>}
        {post.isError && (
          <span className="text-xs text-danger">{(post.error as Error).message}</span>
        )}
        <Button onClick={() => post.mutate()} disabled={post.isPending || !text.trim()}>
          {post.isPending ? <Loader2 className="animate-spin" size={14} /> : <Send size={14} />}
          Gönder
        </Button>
      </div>
    </div>
  );
}

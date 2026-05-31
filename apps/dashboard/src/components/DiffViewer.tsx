"use client";

import {
  ChevronDown,
  ChevronUp,
  FileCode,
  Loader2,
  MessageSquare,
  MessageSquarePlus,
  Pencil,
  Send,
  Trash2,
  X,
} from "lucide-react";
import { useState, useMemo } from "react";
import { cn } from "@/lib/utils";

export type LineCommentSubmit = (args: {
  path: string;
  line: number;
  lineType: "ADDED" | "REMOVED" | "CONTEXT";
  text: string;
}) => Promise<void>;

export type ExistingComment = {
  id: number;
  version: number;
  text: string;
  author_name: string;
  author_display: string;
  created_at?: number;
  updated_at?: number;
  is_mine: boolean;
  anchor: {
    line?: number;
    line_type?: string;
    file_type?: string;
    path?: string;
  };
};

export type CommentEditSubmit = (args: {
  id: number;
  version: number;
  text: string;
}) => Promise<void>;

export type CommentDeleteSubmit = (args: {
  id: number;
  version: number;
}) => Promise<void>;

// ----- Types -----

export type BitbucketLine = {
  source?: number;
  destination?: number;
  line: string;
  truncated?: boolean;
  conflictMarker?: string;
};

export type BitbucketSegment = {
  type: "CONTEXT" | "ADDED" | "REMOVED";
  lines: BitbucketLine[];
};

export type BitbucketHunk = {
  context?: string;
  sourceLine: number;
  sourceSpan: number;
  destinationLine: number;
  destinationSpan: number;
  segments: BitbucketSegment[];
  truncated?: boolean;
};

export type BitbucketFileDiff = {
  source?: { toString: string } | null;
  destination?: { toString: string } | null;
  hunks?: BitbucketHunk[] | null;
  truncated?: boolean;
  binary?: boolean;
};

export type BitbucketDiffResponse = {
  fromHash?: string;
  toHash?: string;
  diffs?: BitbucketFileDiff[];
  truncated?: boolean;
  error?: string;
};

type DiffStat = { plus: number; minus: number };

function statForFile(file: BitbucketFileDiff): DiffStat {
  let plus = 0;
  let minus = 0;
  for (const h of file.hunks || []) {
    for (const seg of h.segments || []) {
      if (seg.type === "ADDED") plus += seg.lines.length;
      else if (seg.type === "REMOVED") minus += seg.lines.length;
    }
  }
  return { plus, minus };
}

// ----- Main viewer -----

export function DiffViewer({
  data,
  filePath,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  data: BitbucketDiffResponse | undefined;
  filePath: string;
  comments?: ExistingComment[];
  onAddComment?: LineCommentSubmit;
  onEditComment?: CommentEditSubmit;
  onDeleteComment?: CommentDeleteSubmit;
}) {
  if (!data) {
    return <div className="p-4 text-sm text-muted">Diff yükleniyor…</div>;
  }
  if (data.error) {
    return <div className="p-4 text-sm text-danger">Hata: {data.error}</div>;
  }
  if (!data.diffs || data.diffs.length === 0) {
    return (
      <div className="p-4 text-sm text-muted">
        Bu dosya için diff yok (binary, rename, ya da boş değişiklik olabilir).
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {data.diffs.map((file, i) => (
        <FileBlock
          key={i}
          file={file}
          fallbackPath={filePath}
          comments={comments}
          onAddComment={onAddComment}
          onEditComment={onEditComment}
          onDeleteComment={onDeleteComment}
        />
      ))}
    </div>
  );
}

function FileBlock({
  file,
  fallbackPath,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  file: BitbucketFileDiff;
  fallbackPath: string;
  comments?: ExistingComment[];
  onAddComment?: LineCommentSubmit;
  onEditComment?: CommentEditSubmit;
  onDeleteComment?: CommentDeleteSubmit;
}) {
  const path =
    file.destination?.toString || file.source?.toString || fallbackPath;
  const renamed =
    file.source?.toString &&
    file.destination?.toString &&
    file.source.toString !== file.destination.toString;
  const stat = useMemo(() => statForFile(file), [file]);
  const [collapsed, setCollapsed] = useState(false);

  if (file.binary) {
    return (
      <div className="rounded-md border border-border bg-surface/40">
        <FileHeader path={path} stat={stat} />
        <div className="px-3 py-3 text-xs text-muted">İkili (binary) dosya — diff gösterilemez</div>
      </div>
    );
  }

  return (
    <div className="rounded-md border border-border bg-surface/40 overflow-hidden">
      <button
        onClick={() => setCollapsed(!collapsed)}
        className="w-full flex items-center"
      >
        <div className="flex-1 min-w-0">
          <FileHeader path={path} stat={stat} renamed={renamed ? file.source!.toString : undefined} />
        </div>
        <div className="px-3 text-muted">
          {collapsed ? <ChevronDown size={14} /> : <ChevronUp size={14} />}
        </div>
      </button>
      {!collapsed && (
        <div className="border-t border-border bg-bg/40">
          {(file.hunks || []).map((h, j) => (
            <HunkBlock
              key={j}
              hunk={h}
              filePath={path}
              comments={comments}
              onAddComment={onAddComment}
              onEditComment={onEditComment}
              onDeleteComment={onDeleteComment}
            />
          ))}
          {file.truncated && (
            <div className="px-3 py-2 text-xs text-warn border-t border-border">
              ⚠️ Diff truncated (çok büyük dosya)
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function FileHeader({
  path,
  stat,
  renamed,
}: {
  path: string;
  stat: DiffStat;
  renamed?: string;
}) {
  const parts = path.split("/");
  const fileName = parts.pop() || path;
  const dir = parts.join("/");
  return (
    <div className="px-3 py-2.5 flex items-center gap-2 text-left">
      <FileCode size={14} className="text-muted shrink-0" />
      <div className="flex-1 min-w-0 truncate">
        {dir && <span className="text-muted text-xs">{dir}/</span>}
        <span className="font-medium text-sm">{fileName}</span>
        {renamed && (
          <span className="ml-2 text-[11px] text-muted italic">← {renamed}</span>
        )}
      </div>
      <div className="flex items-center gap-1.5 text-xs font-mono shrink-0">
        {stat.plus > 0 && <span className="text-success">+{stat.plus}</span>}
        {stat.minus > 0 && <span className="text-danger">−{stat.minus}</span>}
      </div>
    </div>
  );
}

function HunkBlock({
  hunk,
  filePath,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  hunk: BitbucketHunk;
  filePath: string;
  comments?: ExistingComment[];
  onAddComment?: LineCommentSubmit;
  onEditComment?: CommentEditSubmit;
  onDeleteComment?: CommentDeleteSubmit;
}) {
  const allLines = useMemo(() => {
    const rows: { type: BitbucketSegment["type"]; line: BitbucketLine }[] = [];
    for (const seg of hunk.segments || []) {
      for (const ln of seg.lines || []) {
        rows.push({ type: seg.type, line: ln });
      }
    }
    return rows;
  }, [hunk]);

  type Composer = { idx: number; line: number; lineType: BitbucketSegment["type"] };
  const [composer, setComposer] = useState<Composer | null>(null);
  const [posted, setPosted] = useState<
    Record<number, { kind: "ok" | "err"; line: number; msg?: string }>
  >({});

  // Bu hunk'ın satır numaralarına ait yorumlar (path zaten file bazlı filtrelenmiş)
  const commentsByLine = useMemo(() => {
    const map: Record<string, ExistingComment[]> = {};
    for (const c of comments || []) {
      const ln = c.anchor?.line;
      const lt = c.anchor?.line_type;
      if (!ln) continue;
      const key = `${ln}:${lt || "ANY"}`;
      (map[key] ??= []).push(c);
    }
    return map;
  }, [comments]);

  function commentsForRow(line: number, lineType: BitbucketSegment["type"]): ExistingComment[] {
    return [
      ...(commentsByLine[`${line}:${lineType}`] || []),
      ...(commentsByLine[`${line}:ANY`] || []),
    ];
  }

  return (
    <div className="text-[12px] font-mono">
      <div className="px-3 py-1 bg-accent/10 text-accent border-y border-border sticky top-0 z-10">
        @@ -{hunk.sourceLine},{hunk.sourceSpan} +{hunk.destinationLine},{hunk.destinationSpan} @@
        {hunk.context && <span className="text-muted ml-3">{hunk.context}</span>}
      </div>
      <table className="w-full border-collapse">
        <tbody>
          {allLines.map((row, i) => {
            const isAdded = row.type === "ADDED";
            const isRemoved = row.type === "REMOVED";
            const lineNum = isAdded
              ? row.line.destination
              : isRemoved
                ? row.line.source
                : row.line.destination || row.line.source;
            const lineComments = lineNum ? commentsForRow(lineNum, row.type) : [];
            return (
              <DiffRow
                key={i}
                type={row.type}
                line={row.line}
                canComment={!!onAddComment && !!lineNum}
                isCommenting={composer?.idx === i}
                commentCount={lineComments.length}
                onAddComment={() =>
                  setComposer(
                    composer?.idx === i
                      ? null
                      : { idx: i, line: lineNum!, lineType: row.type }
                  )
                }
              />
            );
          })}
        </tbody>
      </table>

      {/* Mevcut yorumlar — satır bazlı listele */}
      {comments && comments.length > 0 && (
        <div className="sticky left-0 px-3 pb-2 pt-2 max-w-3xl space-y-2">
          <div className="text-[10px] uppercase tracking-wide text-muted font-sans">
            Yorumlar ({comments.length})
          </div>
          {comments.map((c) => (
            <CommentItem
              key={c.id}
              comment={c}
              onEdit={onEditComment}
              onDelete={onDeleteComment}
            />
          ))}
        </div>
      )}

      {/* Composer + posted notifications — tablo dışında, container genişliğinde */}
      {composer && onAddComment && (
        <div className="sticky left-0 px-3 pb-3 pt-2 max-w-3xl">
          <div className="text-[11px] text-muted mb-1.5">
            <span className="font-mono text-accent">{filePath.split("/").pop()}</span> satır{" "}
            <span className="font-mono">{composer.line}</span> ({composer.lineType})
          </div>
          <InlineComposer
            onCancel={() => setComposer(null)}
            onSubmit={async (text) => {
              try {
                await onAddComment({
                  path: filePath,
                  line: composer.line,
                  lineType: composer.lineType,
                  text,
                });
                setPosted((p) => ({
                  ...p,
                  [composer.idx]: { kind: "ok", line: composer.line },
                }));
                setComposer(null);
              } catch (e: any) {
                setPosted((p) => ({
                  ...p,
                  [composer.idx]: {
                    kind: "err",
                    line: composer.line,
                    msg: e.message || "hata",
                  },
                }));
              }
            }}
          />
        </div>
      )}

      {/* Geçmiş yorum sonuçları */}
      {Object.entries(posted).length > 0 && (
        <div className="sticky left-0 px-3 pb-2 max-w-3xl space-y-1">
          {Object.entries(posted).map(([idx, info]) => (
            <div
              key={idx}
              className={cn(
                "text-[11px] px-2 py-1 rounded font-sans",
                info.kind === "ok"
                  ? "text-success bg-success/10 border border-success/20"
                  : "text-danger bg-danger/10 border border-danger/20"
              )}
            >
              {info.kind === "ok"
                ? `✓ Yorum Bitbucket'a gönderildi (satır ${info.line})`
                : `✗ Satır ${info.line}: ${info.msg}`}
            </div>
          ))}
        </div>
      )}

      {hunk.truncated && (
        <div className="px-3 py-1.5 text-[11px] text-warn">⚠️ hunk truncated</div>
      )}
    </div>
  );
}

function DiffRow({
  type,
  line,
  canComment,
  isCommenting,
  commentCount,
  onAddComment,
}: {
  type: BitbucketSegment["type"];
  line: BitbucketLine;
  canComment?: boolean;
  isCommenting?: boolean;
  commentCount?: number;
  onAddComment?: () => void;
}) {
  const isAdded = type === "ADDED";
  const isRemoved = type === "REMOVED";
  const bg = isAdded ? "bg-success/10" : isRemoved ? "bg-danger/10" : "";
  const gutter = isAdded
    ? "border-l-2 border-success/60"
    : isRemoved
      ? "border-l-2 border-danger/60"
      : "border-l-2 border-transparent";

  const sign = isAdded ? "+" : isRemoved ? "−" : " ";
  const signColor = isAdded ? "text-success" : isRemoved ? "text-danger" : "text-muted";

  return (
    <tr
      className={cn(
        "group hover:bg-border/30",
        bg,
        isCommenting && "outline outline-1 outline-accent/60"
      )}
    >
      <td className="text-right px-2 py-0.5 text-muted/70 select-none w-12 border-r border-border/30 align-top">
        {!isAdded ? line.source : ""}
      </td>
      <td className="text-right px-2 py-0.5 text-muted/70 select-none w-12 border-r border-border/30 align-top relative">
        {!isRemoved ? line.destination : ""}
        {!!commentCount && commentCount > 0 && (
          <span
            title={`${commentCount} yorum var`}
            className="absolute -left-1 top-0.5 inline-flex items-center justify-center w-3.5 h-3.5 rounded-full bg-warn/90 text-bg text-[8px] font-bold"
          >
            {commentCount}
          </span>
        )}
        {canComment && (
          <button
            onClick={onAddComment}
            title={isCommenting ? "Yorumlama modunu kapat" : "Bu satıra yorum ekle"}
            className={cn(
              "absolute -right-3 top-0.5 z-10 rounded-sm",
              "bg-accent text-bg shadow-md",
              "transition-opacity p-0.5 hover:scale-110",
              isCommenting ? "opacity-100" : "opacity-0 group-hover:opacity-100"
            )}
          >
            <MessageSquarePlus size={11} />
          </button>
        )}
      </td>
      <td className={cn("text-center w-6 select-none align-top", signColor, gutter)}>{sign}</td>
      <td className="px-2 py-0.5 whitespace-pre break-all align-top">
        {line.line || "\u00A0"}
        {line.truncated && <span className="ml-2 text-[10px] text-warn">[truncated]</span>}
      </td>
    </tr>
  );
}

function CommentItem({
  comment,
  onEdit,
  onDelete,
}: {
  comment: ExistingComment;
  onEdit?: CommentEditSubmit;
  onDelete?: CommentDeleteSubmit;
}) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(comment.text);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);

  const ts = comment.updated_at || comment.created_at;
  const dateStr = ts ? new Date(ts).toLocaleString("tr-TR") : "";

  if (editing) {
    return (
      <div className="bg-surface border border-accent/40 rounded-md p-3 text-sm font-sans">
        <div className="text-[11px] text-muted mb-1.5">
          {comment.author_display} ({comment.anchor?.line && `satır ${comment.anchor.line}`})
        </div>
        <textarea
          autoFocus
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={3}
          className="w-full bg-bg border border-border rounded px-2 py-1.5 text-[12px] outline-none focus:border-accent/60 resize-y"
          onKeyDown={(e) => {
            if (e.key === "Escape") {
              setEditing(false);
              setText(comment.text);
            }
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              if (!busy && text.trim() && onEdit) {
                setBusy(true);
                setErr(null);
                onEdit({ id: comment.id, version: comment.version, text })
                  .then(() => {
                    setBusy(false);
                    setEditing(false);
                  })
                  .catch((e: any) => {
                    setBusy(false);
                    setErr(e.message || "hata");
                  });
              }
            }
          }}
        />
        {err && <div className="text-[11px] text-danger mt-1">✗ {err}</div>}
        <div className="flex items-center justify-end gap-2 mt-2">
          <button
            onClick={() => {
              setEditing(false);
              setText(comment.text);
              setErr(null);
            }}
            className="px-2 py-1 text-[11px] rounded text-muted hover:text-text border border-border"
          >
            <X size={11} className="inline mr-1" /> İptal
          </button>
          <button
            onClick={() => {
              if (!text.trim() || busy || !onEdit) return;
              setBusy(true);
              setErr(null);
              onEdit({ id: comment.id, version: comment.version, text })
                .then(() => {
                  setBusy(false);
                  setEditing(false);
                })
                .catch((e: any) => {
                  setBusy(false);
                  setErr(e.message || "hata");
                });
            }}
            disabled={busy || !text.trim()}
            className="px-2 py-1 text-[11px] rounded bg-accent text-bg hover:bg-accent/90 disabled:opacity-40"
          >
            {busy ? <Loader2 size={11} className="inline mr-1 animate-spin" /> : <Pencil size={11} className="inline mr-1" />}
            Kaydet
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-surface/70 border border-border rounded-md p-2.5 text-sm font-sans group/comment">
      <div className="flex items-start justify-between gap-2">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 text-[11px] text-muted">
            <MessageSquare size={11} />
            <span className={cn("font-medium", comment.is_mine ? "text-accent" : "text-text")}>
              {comment.author_display}
            </span>
            {comment.is_mine && <span className="text-accent">(sen)</span>}
            {comment.anchor?.line && (
              <span className="font-mono">satır {comment.anchor.line}</span>
            )}
            {dateStr && <span>· {dateStr}</span>}
          </div>
          <div className="text-[13px] mt-1 whitespace-pre-wrap break-words">
            {comment.text}
          </div>
          {err && <div className="text-[11px] text-danger mt-1">✗ {err}</div>}
        </div>
        {comment.is_mine && (onEdit || onDelete) && (
          <div className="opacity-0 group-hover/comment:opacity-100 transition-opacity flex gap-1 shrink-0">
            {onEdit && (
              <button
                onClick={() => setEditing(true)}
                title="Düzenle"
                className="p-1 rounded text-muted hover:text-accent hover:bg-border/40"
              >
                <Pencil size={12} />
              </button>
            )}
            {onDelete && (
              <button
                onClick={() => setConfirming(true)}
                title="Sil"
                className="p-1 rounded text-muted hover:text-danger hover:bg-border/40"
              >
                <Trash2 size={12} />
              </button>
            )}
          </div>
        )}
      </div>
      {confirming && onDelete && (
        <div className="mt-2 pt-2 border-t border-border flex items-center justify-end gap-2 text-[11px]">
          <span className="text-warn mr-auto">Bu yorumu silmek istediğine emin misin?</span>
          <button
            onClick={() => setConfirming(false)}
            className="px-2 py-0.5 rounded text-muted hover:text-text border border-border"
          >
            Vazgeç
          </button>
          <button
            onClick={() => {
              setBusy(true);
              setErr(null);
              onDelete({ id: comment.id, version: comment.version })
                .then(() => {
                  setBusy(false);
                  setConfirming(false);
                })
                .catch((e: any) => {
                  setBusy(false);
                  setErr(e.message || "silinemedi");
                  setConfirming(false);
                });
            }}
            disabled={busy}
            className="px-2 py-0.5 rounded bg-danger text-bg hover:bg-danger/90 disabled:opacity-50"
          >
            {busy ? <Loader2 size={10} className="inline mr-1 animate-spin" /> : <Trash2 size={10} className="inline mr-1" />}
            Evet, sil
          </button>
        </div>
      )}
    </div>
  );
}

function InlineComposer({
  onSubmit,
  onCancel,
}: {
  onSubmit: (text: string) => Promise<void>;
  onCancel: () => void;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <div className="bg-surface border border-accent/30 rounded-md p-3">
      <textarea
        autoFocus
        value={text}
        onChange={(e) => setText(e.target.value)}
        rows={3}
        placeholder="Bu satıra yorum…"
        className="w-full bg-bg border border-border rounded px-2 py-1.5 text-[12px] outline-none focus:border-accent/60 font-sans resize-y"
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            if (text.trim() && !busy) {
              e.preventDefault();
              setBusy(true);
              onSubmit(text).finally(() => setBusy(false));
            }
          }
          if (e.key === "Escape") onCancel();
        }}
      />
      <div className="flex items-center justify-end gap-2 mt-2">
        <span className="text-[10px] text-muted mr-auto">
          Cmd/Ctrl+Enter ile gönder · Esc ile kapat
        </span>
        <button
          onClick={onCancel}
          className="px-2 py-1 text-[11px] rounded text-muted hover:text-text border border-border"
        >
          <X size={11} className="inline mr-1" /> İptal
        </button>
        <button
          onClick={() => {
            if (!text.trim() || busy) return;
            setBusy(true);
            onSubmit(text).finally(() => setBusy(false));
          }}
          disabled={busy || !text.trim()}
          className="px-2 py-1 text-[11px] rounded bg-accent text-bg hover:bg-accent/90 disabled:opacity-40"
        >
          {busy ? (
            <Loader2 size={11} className="inline mr-1 animate-spin" />
          ) : (
            <Send size={11} className="inline mr-1" />
          )}
          Gönder
        </button>
      </div>
    </div>
  );
}

// ----- File list (sidebar) -----

export type ChangeItem = {
  path: string;
  src_path?: string | null;
  type: string;
};

export function FileList({
  changes,
  selected,
  onSelect,
}: {
  changes: ChangeItem[];
  selected: string | null;
  onSelect: (p: string) => void;
}) {
  const [filter, setFilter] = useState("");
  const filtered = useMemo(() => {
    if (!filter) return changes;
    const q = filter.toLowerCase();
    return changes.filter((c) => c.path.toLowerCase().includes(q));
  }, [changes, filter]);

  return (
    <div className="flex flex-col h-full">
      <div className="p-2 border-b border-border">
        <input
          type="text"
          placeholder="Dosya ara…"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          className="w-full bg-bg border border-border rounded px-2 py-1 text-xs outline-none focus:border-accent/60"
        />
      </div>
      <div className="flex-1 overflow-y-auto scrollbar-thin">
        {filtered.length === 0 && (
          <div className="p-3 text-xs text-muted">Eşleşen dosya yok</div>
        )}
        {filtered.map((c) => {
          const parts = c.path.split("/");
          const file = parts.pop() || c.path;
          const dir = parts.join("/");
          const isSel = selected === c.path;
          const tag = typeTag(c.type);
          return (
            <button
              key={c.path}
              onClick={() => onSelect(c.path)}
              title={c.path}
              className={cn(
                "w-full text-left px-2 py-1.5 text-[11px] hover:bg-border/40 border-l-2 flex items-center gap-2",
                isSel
                  ? "bg-border/60 border-l-accent"
                  : "border-l-transparent"
              )}
            >
              <span
                className={cn(
                  "shrink-0 w-7 text-center font-mono text-[9px] uppercase rounded px-1 py-0.5",
                  tag.cls
                )}
              >
                {tag.label}
              </span>
              <div className="flex-1 min-w-0 truncate">
                <span className="font-medium">{file}</span>
                {dir && (
                  <span className="text-muted ml-1 text-[10px]">{dir}</span>
                )}
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}

function typeTag(t: string) {
  switch (t) {
    case "ADD":
      return { cls: "bg-success/20 text-success", label: "+" };
    case "MODIFY":
      return { cls: "bg-warn/20 text-warn", label: "M" };
    case "DELETE":
      return { cls: "bg-danger/20 text-danger", label: "−" };
    case "RENAME":
      return { cls: "bg-accent/20 text-accent", label: "R" };
    case "COPY":
      return { cls: "bg-accent/20 text-accent", label: "C" };
    default:
      return { cls: "bg-border/40 text-muted", label: t.slice(0, 3) };
  }
}

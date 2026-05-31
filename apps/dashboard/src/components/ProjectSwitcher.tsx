"use client";

import { ChevronDown, Check, FolderKanban, Plus } from "lucide-react";
import Link from "next/link";
import { useState, useRef, useEffect } from "react";
import { useProjects, useActivateProject, useActiveProject } from "@/lib/projects";

export function ProjectSwitcher() {
  const { data } = useProjects();
  const active = useActiveProject();
  const activate = useActivateProject();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, []);

  if (!data) {
    return <div className="h-9 w-44 bg-surface/40 rounded-md animate-pulse" />;
  }

  const visible = data.projects.filter((p) => !p.is_archived);

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(!open)}
        className="flex items-center gap-2 px-3 py-1.5 rounded-md bg-surface/60 border border-border hover:bg-border/40 text-sm w-full"
      >
        <span
          className="w-2 h-2 rounded-full shrink-0"
          style={{ background: active?.color || "#666" }}
        />
        <span className="flex-1 text-left truncate">
          {active?.name || "(proje seç)"}
        </span>
        <ChevronDown size={14} className="text-muted shrink-0" />
      </button>

      {open && (
        <div className="absolute top-full left-0 mt-1 w-64 bg-surface border border-border rounded-md shadow-lg z-50 overflow-hidden">
          <div className="px-3 py-1.5 text-[11px] uppercase tracking-wide text-muted border-b border-border">
            Projeler
          </div>
          <div className="max-h-72 overflow-y-auto scrollbar-thin py-1">
            {visible.length === 0 && (
              <div className="px-3 py-2 text-xs text-muted">
                Henüz proje yok. Ayarlar'dan ekle.
              </div>
            )}
            {visible.map((p) => (
              <button
                key={p.id}
                onClick={() => {
                  activate.mutate(p.id);
                  setOpen(false);
                }}
                className="w-full flex items-center gap-2 px-3 py-2 hover:bg-border/40 text-sm"
              >
                <span
                  className="w-2 h-2 rounded-full shrink-0"
                  style={{ background: p.color }}
                />
                <span className="flex-1 text-left truncate">{p.name}</span>
                {p.id === data.active_id && <Check size={14} className="text-success" />}
              </button>
            ))}
          </div>
          <Link
            href="/settings"
            onClick={() => setOpen(false)}
            className="flex items-center gap-2 px-3 py-2 border-t border-border text-xs text-muted hover:text-text hover:bg-border/40"
          >
            <Plus size={12} /> Proje yönet…
          </Link>
        </div>
      )}
    </div>
  );
}

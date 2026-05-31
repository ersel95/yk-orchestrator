"use client";

import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Loader2, Plus, Save, Archive } from "lucide-react";
import { Card, CardTitle, Badge, Button, Input } from "@/components/ui";
import { api, cn } from "@/lib/utils";
import {
  Project,
  useProjects,
  useCreateProject,
  useUpdateProject,
  useArchiveProject,
  useActivateProject,
} from "@/lib/projects";

export default function SettingsPage() {
  const [tab, setTab] = useState<"projects" | "global">("projects");

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold">Ayarlar</h1>
        <p className="text-sm text-muted">
          Projeler ve global yapılandırma. Jira/Bitbucket hesap bilgisi global, diğerleri proje bazlı.
        </p>
      </div>

      <div className="flex gap-2 border-b border-border">
        {[
          { k: "projects", label: "Projeler" },
          { k: "global", label: "Global" },
        ].map((t) => (
          <button
            key={t.k}
            onClick={() => setTab(t.k as any)}
            className={cn(
              "px-3 py-2 text-sm border-b-2 -mb-px",
              tab === t.k
                ? "border-accent text-accent"
                : "border-transparent text-muted hover:text-text"
            )}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "projects" && <ProjectsTab />}
      {tab === "global" && <GlobalTab />}
    </div>
  );
}

function ProjectsTab() {
  const { data, isLoading } = useProjects();
  const [editing, setEditing] = useState<Project | null>(null);
  const [creating, setCreating] = useState(false);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
      <Card className="lg:col-span-1">
        <CardTitle>
          <div className="flex items-center justify-between">
            <span>Tüm Projeler</span>
            <Button
              variant="ghost"
              onClick={() => {
                setCreating(true);
                setEditing(null);
              }}
            >
              <Plus size={14} /> Yeni
            </Button>
          </div>
        </CardTitle>
        {isLoading && <div className="text-sm text-muted">Yükleniyor…</div>}
        <ul className="space-y-1">
          {data?.projects.map((p) => (
            <li key={p.id}>
              <button
                onClick={() => {
                  setEditing(p);
                  setCreating(false);
                }}
                className={cn(
                  "w-full text-left px-3 py-2 rounded-md hover:bg-border/30",
                  editing?.id === p.id ? "bg-border/40" : ""
                )}
              >
                <div className="flex items-center gap-2">
                  <span
                    className="w-2 h-2 rounded-full shrink-0"
                    style={{ background: p.color }}
                  />
                  <span className="text-sm flex-1">{p.name}</span>
                  {p.id === data?.active_id && (
                    <Badge className="bg-accent/20 text-accent">aktif</Badge>
                  )}
                  {p.is_archived && <Badge>arşiv</Badge>}
                </div>
                <div className="text-[11px] text-muted ml-4 truncate">{p.slug}</div>
              </button>
            </li>
          ))}
        </ul>
      </Card>

      <Card className="lg:col-span-2">
        {!editing && !creating && (
          <div className="text-sm text-muted text-center py-10">
            Sol listeden bir proje seç veya "Yeni" ile ekle
          </div>
        )}
        {(editing || creating) && (
          <ProjectForm
            key={editing?.id ?? "new"}
            project={editing}
            isNew={creating}
            onClose={() => {
              setEditing(null);
              setCreating(false);
            }}
          />
        )}
      </Card>
    </div>
  );
}

function ProjectForm({
  project,
  isNew,
  onClose,
}: {
  project: Project | null;
  isNew: boolean;
  onClose: () => void;
}) {
  const create = useCreateProject();
  const update = useUpdateProject();
  const archive = useArchiveProject();
  const activate = useActivateProject();
  const { data } = useProjects();
  const isActive = project && data?.active_id === project.id;

  const [form, setForm] = useState<Partial<Project>>(
    project || {
      name: "",
      slug: "",
      color: "#60A5FA",
      jira_project_keys: "",
      bitbucket_workspace: "",
      bitbucket_repo: "",
      local_repo_path: "",
      git_default_branch: "develop",
      fastlane_project_dir: "",
      fastlane_lane: "beta",
    }
  );

  function set<K extends keyof Project>(k: K, v: Project[K]) {
    setForm((f) => ({ ...f, [k]: v }));
  }

  async function save() {
    if (isNew) {
      await create.mutateAsync(form);
    } else if (project) {
      await update.mutateAsync({ id: project.id, ...form });
    }
    onClose();
  }

  return (
    <div className="space-y-4">
      <CardTitle>
        <div className="flex items-center justify-between">
          <span>{isNew ? "Yeni Proje" : project?.name}</span>
          <div className="flex gap-2">
            {project && !isActive && (
              <Button variant="ghost" onClick={() => activate.mutate(project.id)}>
                Aktif yap
              </Button>
            )}
            {project && !project.is_archived && (
              <Button variant="ghost" onClick={() => archive.mutate(project.id)}>
                <Archive size={14} /> Arşivle
              </Button>
            )}
          </div>
        </div>
      </CardTitle>

      <div className="grid grid-cols-2 gap-3">
        <Field label="Görüntü Adı">
          <Input
            value={form.name || ""}
            onChange={(e) => set("name", e.target.value)}
            placeholder="Mobile Banking iOS"
          />
        </Field>
        <Field label="Slug (kısa key)">
          <Input
            value={form.slug || ""}
            onChange={(e) => set("slug", e.target.value)}
            placeholder="mobile-banking"
          />
        </Field>
      </div>

      <Field label="Renk">
        <div className="flex gap-2">
          {["#60A5FA", "#34D399", "#FBBF24", "#F87171", "#A78BFA", "#FB7185"].map((c) => (
            <button
              key={c}
              onClick={() => set("color", c)}
              className={cn(
                "w-7 h-7 rounded-full border-2",
                form.color === c ? "border-text" : "border-transparent"
              )}
              style={{ background: c }}
            />
          ))}
        </div>
      </Field>

      <div className="border-t border-border pt-4">
        <div className="text-xs uppercase text-muted mb-2">Jira & Bitbucket</div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Jira project keys (CSV)">
            <Input
              value={form.jira_project_keys || ""}
              onChange={(e) => set("jira_project_keys", e.target.value)}
              placeholder="IOS,MOB"
            />
          </Field>
          <Field label="Bitbucket workspace / project key">
            <Input
              value={form.bitbucket_workspace || ""}
              onChange={(e) => set("bitbucket_workspace", e.target.value)}
              placeholder="mobile"
            />
          </Field>
          <Field label="Bitbucket repo slug">
            <Input
              value={form.bitbucket_repo || ""}
              onChange={(e) => set("bitbucket_repo", e.target.value)}
              placeholder="ios-app"
            />
          </Field>
          <Field label="Default branch">
            <Input
              value={form.git_default_branch || ""}
              onChange={(e) => set("git_default_branch", e.target.value)}
              placeholder="develop"
            />
          </Field>
        </div>
      </div>

      <div className="border-t border-border pt-4">
        <div className="text-xs uppercase text-muted mb-2">Lokal & TestFlight</div>
        <div className="grid grid-cols-1 gap-3">
          <Field label="Lokal repo path">
            <Input
              value={form.local_repo_path || ""}
              onChange={(e) => set("local_repo_path", e.target.value)}
              placeholder="/Users/ersel/Workspace/ios-app"
            />
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Fastlane proje dizini">
              <Input
                value={form.fastlane_project_dir || ""}
                onChange={(e) => set("fastlane_project_dir", e.target.value)}
                placeholder="(boşsa lokal repo path)"
              />
            </Field>
            <Field label="Fastlane lane">
              <Input
                value={form.fastlane_lane || ""}
                onChange={(e) => set("fastlane_lane", e.target.value)}
                placeholder="beta"
              />
            </Field>
          </div>
        </div>
      </div>

      <div className="flex gap-2 justify-end pt-2 border-t border-border">
        <Button variant="ghost" onClick={onClose}>
          Vazgeç
        </Button>
        <Button onClick={save} disabled={create.isPending || update.isPending}>
          {create.isPending || update.isPending ? (
            <Loader2 className="animate-spin" size={14} />
          ) : (
            <Save size={14} />
          )}
          Kaydet
        </Button>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="text-[11px] uppercase tracking-wide text-muted">{label}</label>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function GlobalTab() {
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => api<any>("/api/settings"),
  });
  const data = settings.data;
  if (!data) return <div className="text-sm text-muted">Yükleniyor…</div>;

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-5">
      <Card>
        <CardTitle>LLM (Lokal)</CardTitle>
        <Row label="Base URL" value={data.llm.base_url} />
        <Row label="Genel model" value={data.llm.general} />
        <Row label="Kod modeli" value={data.llm.code} />
        <Row label="Embed modeli" value={data.llm.embed} />
      </Card>

      <Card>
        <CardTitle>Jira (global hesap)</CardTitle>
        <Row label="URL" value={data.jira.base_url || "—"} />
        <Row label="Kullanıcı" value={data.jira.email || "—"} />
        <Row label="Token" value={data.jira.configured ? "***" : "tanımsız"} />
      </Card>

      <Card>
        <CardTitle>Bitbucket (global hesap)</CardTitle>
        <Row label="URL" value={data.bitbucket.base_url || "—"} />
        <Row label="Kullanıcı" value={data.bitbucket.username || "—"} />
        <Row label="App password" value={data.bitbucket.configured ? "***" : "tanımsız"} />
      </Card>

      <Card>
        <CardTitle>Scheduler</CardTitle>
        <Row
          label="Otomatik fetch"
          value={`Her gün ${String(data.scheduler.daily_fetch_hour).padStart(2, "0")}:${String(
            data.scheduler.daily_fetch_minute
          ).padStart(2, "0")}`}
        />
      </Card>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between py-1.5 border-b border-border/50 last:border-0">
      <span className="text-xs text-muted">{label}</span>
      <span className="text-xs font-mono">{value}</span>
    </div>
  );
}

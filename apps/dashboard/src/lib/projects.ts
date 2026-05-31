"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./utils";

export type Project = {
  id: number;
  name: string;
  slug: string;
  color: string;
  jira_project_keys: string;
  bitbucket_workspace: string;
  bitbucket_repo: string;
  local_repo_path: string;
  git_default_branch: string;
  fastlane_project_dir: string;
  fastlane_lane: string;
  is_archived: boolean;
  sort_order: number;
};

export type ProjectsResponse = {
  projects: Project[];
  active_id: number | null;
};

export function useProjects() {
  return useQuery<ProjectsResponse>({
    queryKey: ["projects"],
    queryFn: () => api<ProjectsResponse>("/api/projects"),
    staleTime: 60_000,
  });
}

export function useActiveProject() {
  const { data } = useProjects();
  if (!data) return null;
  return data.projects.find((p) => p.id === data.active_id) || null;
}

export function useActivateProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => api(`/api/projects/${id}/activate`, { method: "POST" }),
    onSuccess: () => {
      // Active project değişti — tüm proje-bağımlı veriyi yenile
      qc.invalidateQueries({ queryKey: ["projects"] });
      qc.invalidateQueries({ queryKey: ["standup"] });
      qc.invalidateQueries({ queryKey: ["standups"] });
      qc.invalidateQueries({ queryKey: ["prs"] });
      qc.invalidateQueries({ queryKey: ["transcripts"] });
      qc.invalidateQueries({ queryKey: ["jira"] });
      qc.invalidateQueries({ queryKey: ["testflight-status"] });
    },
  });
}

export function useCreateProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Partial<Project>) =>
      api<Project>("/api/projects", { method: "POST", body: JSON.stringify(body) }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  });
}

export function useUpdateProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: number } & Partial<Project>) =>
      api<Project>(`/api/projects/${id}`, { method: "PATCH", body: JSON.stringify(body) }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  });
}

export function useArchiveProject() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => api(`/api/projects/${id}`, { method: "DELETE" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  });
}

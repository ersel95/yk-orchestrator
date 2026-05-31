"use client";

import { useQuery } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { AlertCircle, Loader2, Rocket } from "lucide-react";
import { Button, Card, CardTitle, EmptyState } from "@/components/ui";
import { API_BASE, api } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";

export default function TestFlightPage() {
  const project = useActiveProject();
  const projectId = project?.id;
  const status = useQuery({
    queryKey: ["testflight-status", projectId],
    enabled: !!projectId,
    queryFn: () =>
      api<{ configured: boolean }>(`/api/testflight/status?project_id=${projectId}`),
  });

  const [running, setRunning] = useState(false);
  const [logs, setLogs] = useState<string[]>([]);
  const [confirmed, setConfirmed] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  async function start() {
    setRunning(true);
    setLogs([]);
    abortRef.current = new AbortController();
    try {
      const res = await fetch(`${API_BASE}/api/testflight/upload`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project_id: projectId }),
        signal: abortRef.current.signal,
      });
      if (!res.body) throw new Error("Stream yok");
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        const events = buf.split("\n\n");
        buf = events.pop() || "";
        for (const ev of events) {
          const eventLine = ev.split("\n").find((l) => l.startsWith("event:"));
          const dataLine = ev.split("\n").find((l) => l.startsWith("data:"));
          if (!dataLine) continue;
          const data = JSON.parse(dataLine.slice(5).trim() || "null");
          if (eventLine?.includes("line")) {
            setLogs((l) => [...l, data]);
          }
        }
      }
    } catch (e) {
      setLogs((l) => [...l, "[ERR] " + (e as Error).message]);
    } finally {
      setRunning(false);
    }
  }

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold">TestFlight</h1>
        <p className="text-sm text-muted">Fastlane ile build + upload. Manuel onay gerekir.</p>
      </div>

      {!status.data?.configured && (
        <Card>
          <div className="flex items-start gap-3">
            <AlertCircle className="text-warn mt-0.5" size={18} />
            <div>
              <div className="font-medium">Fastlane yapılandırılmamış</div>
              <div className="text-xs text-muted">
                .env dosyasında FASTLANE_PROJECT_DIR ayarlı olmalı ve bu dizinde fastlane/ klasörü bulunmalı.
              </div>
            </div>
          </div>
        </Card>
      )}

      <Card>
        <CardTitle>Yükleme Onayı</CardTitle>
        {!confirmed ? (
          <div className="space-y-3">
            <div className="text-sm text-muted">
              "Yükle" butonuna basınca <span className="font-mono text-text">bundle exec fastlane beta</span> komutu çalışacak.
              Build numarası, sürüm ve tüm pipeline çıktısı aşağıda gerçek zamanlı görünür.
            </div>
            <Button onClick={() => setConfirmed(true)} disabled={!status.data?.configured}>
              Anladım, devam et
            </Button>
          </div>
        ) : (
          <div className="space-y-3">
            <Button onClick={start} disabled={running}>
              {running ? <Loader2 className="animate-spin" size={14} /> : <Rocket size={14} />}
              {running ? "Yükleniyor…" : "TestFlight'a Yükle"}
            </Button>
            <pre className="bg-bg border border-border rounded p-3 text-xs font-mono max-h-[60vh] overflow-y-auto scrollbar-thin">
              {logs.length === 0 ? "(çıktı henüz yok)" : logs.join("\n")}
            </pre>
          </div>
        )}
      </Card>
    </div>
  );
}

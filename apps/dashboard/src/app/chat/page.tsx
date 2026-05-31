"use client";

import { useEffect, useRef, useState } from "react";
import { Loader2, Send } from "lucide-react";
import ReactMarkdown from "react-markdown";
import { Button, Card, CardTitle, Textarea, Badge } from "@/components/ui";
import { API_BASE } from "@/lib/utils";
import { useActiveProject } from "@/lib/projects";

type Source = { collection: string; id: string; metadata?: Record<string, unknown> };
type Msg = {
  role: "user" | "assistant";
  content: string;
  sources?: Source[];
};

export default function ChatPage() {
  const [messages, setMessages] = useState<Msg[]>([]);
  const [input, setInput] = useState("");
  const [pending, setPending] = useState(false);
  const [scope, setScope] = useState<"active" | "all">("active");
  const esRef = useRef<EventSource | null>(null);
  const project = useActiveProject();

  useEffect(() => {
    return () => {
      esRef.current?.close();
    };
  }, []);

  function appendDelta(delta: string) {
    setMessages((m) => {
      const last = m[m.length - 1];
      if (!last || last.role !== "assistant") return m;
      return [...m.slice(0, -1), { ...last, content: last.content + delta }];
    });
  }

  function setLastSources(sources: Source[]) {
    setMessages((m) => {
      const last = m[m.length - 1];
      if (!last || last.role !== "assistant") return m;
      return [...m.slice(0, -1), { ...last, sources }];
    });
  }

  function send() {
    if (!input.trim() || pending) return;
    const question = input.trim();
    setMessages((m) => [
      ...m,
      { role: "user", content: question },
      { role: "assistant", content: "" },
    ]);
    setInput("");
    setPending(true);

    const params = new URLSearchParams({ question, scope });
    if (project?.id) params.set("project_id", String(project.id));
    const url = `${API_BASE}/api/chat/stream?${params.toString()}`;
    const es = new EventSource(url);
    esRef.current = es;

    es.addEventListener("sources", (e: MessageEvent) => {
      try {
        setLastSources(JSON.parse(e.data));
      } catch {
        /* ignore */
      }
    });

    es.addEventListener("delta", (e: MessageEvent) => {
      try {
        const chunk = JSON.parse(e.data);
        if (typeof chunk === "string") appendDelta(chunk);
      } catch {
        /* ignore */
      }
    });

    es.addEventListener("done", () => {
      es.close();
      esRef.current = null;
      setPending(false);
    });

    es.onerror = (err) => {
      console.error("SSE hata:", err);
      es.close();
      esRef.current = null;
      setMessages((m) => {
        const last = m[m.length - 1];
        if (!last || last.role !== "assistant") return m;
        const content =
          last.content || "[Bağlantı hatası — backend/LLM kontrol et]";
        return [...m.slice(0, -1), { ...last, content }];
      });
      setPending(false);
    };
  }

  return (
    <div className="space-y-5 h-full flex flex-col">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">Chat</h1>
          <p className="text-sm text-muted">
            Geçmiş daily, transkript, Jira ve PR datanı RAG ile sorgula. Tüm cevaplar lokal LLM ile.
          </p>
        </div>
        <div className="flex items-center gap-1 text-xs bg-surface/60 border border-border rounded-md p-1">
          <button
            onClick={() => setScope("active")}
            className={`px-2 py-1 rounded ${scope === "active" ? "bg-accent/20 text-accent" : "text-muted"}`}
          >
            {project ? `Sadece ${project.name}` : "Aktif proje"}
          </button>
          <button
            onClick={() => setScope("all")}
            className={`px-2 py-1 rounded ${scope === "all" ? "bg-accent/20 text-accent" : "text-muted"}`}
          >
            Tüm projeler
          </button>
        </div>
      </div>

      <Card className="flex-1 flex flex-col gap-3 min-h-[60vh]">
        <div className="flex-1 overflow-y-auto scrollbar-thin space-y-4">
          {messages.length === 0 && (
            <div className="text-sm text-muted text-center py-10">
              <div className="font-medium text-text">Örnek sorular</div>
              <ul className="mt-2 space-y-1">
                <li>"Geçen hafta IOS-1234 için ne konuşmuştuk?"</li>
                <li>"Bu sprint'te benden ne bekleniyor?"</li>
                <li>"Murat'ın bana atadığı son aksiyon neydi?"</li>
              </ul>
            </div>
          )}
          {messages.map((m, i) => (
            <div key={i}>
              <div className={`text-xs mb-1 ${m.role === "user" ? "text-accent" : "text-muted"}`}>
                {m.role === "user" ? "Sen" : "AI"}
              </div>
              <div className="prose prose-invert prose-sm max-w-none">
                <ReactMarkdown>
                  {m.content || (pending && i === messages.length - 1 ? "_yazıyor…_" : "")}
                </ReactMarkdown>
              </div>
              {m.sources && m.sources.length > 0 && (
                <div className="mt-2 flex flex-wrap gap-1">
                  {m.sources.map((s, j) => (
                    <Badge key={j}>
                      {s.collection}#{s.id}
                    </Badge>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
        <div className="flex gap-2">
          <Textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="Soruyu yaz, Cmd/Ctrl+Enter ile gönder…"
            rows={2}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                send();
              }
            }}
          />
          <Button onClick={send} disabled={pending || !input.trim()}>
            {pending ? <Loader2 className="animate-spin" size={14} /> : <Send size={14} />}
            Gönder
          </Button>
        </div>
      </Card>
    </div>
  );
}

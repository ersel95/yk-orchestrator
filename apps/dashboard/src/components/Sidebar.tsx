"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  Calendar,
  GitPullRequest,
  History,
  MessageSquare,
  Mic,
  Settings,
  Smartphone,
  Sparkles,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { ProjectSwitcher } from "./ProjectSwitcher";

const items = [
  { href: "/", label: "Bugün", icon: Calendar },
  { href: "/pull-requests", label: "Pull Request'ler", icon: GitPullRequest },
  { href: "/standups", label: "Daily Geçmişi", icon: History },
  { href: "/transcripts", label: "Transkriptler", icon: Mic },
  { href: "/chat", label: "Chat", icon: MessageSquare },
  { href: "/testflight", label: "TestFlight", icon: Smartphone },
  { href: "/settings", label: "Ayarlar", icon: Settings },
];

export function Sidebar() {
  const pathname = usePathname();
  return (
    <aside className="w-60 shrink-0 border-r border-border bg-surface/40 px-3 py-5 flex flex-col gap-1">
      <div className="flex items-center gap-2 px-3 pb-3">
        <Sparkles className="text-accent" size={20} />
        <div>
          <div className="font-semibold text-sm">YK iOS Orchestrator</div>
          <div className="text-xs text-muted">Lokal AI Agent Hub</div>
        </div>
      </div>
      <div className="px-3 pb-4">
        <ProjectSwitcher />
      </div>
      <nav className="flex flex-col gap-0.5">
        {items.map(({ href, label, icon: Icon }) => {
          const active = pathname === href || (href !== "/" && pathname.startsWith(href));
          return (
            <Link
              key={href}
              href={href}
              className={cn(
                "flex items-center gap-3 px-3 py-2 rounded-md text-sm transition-colors",
                active
                  ? "bg-accent/15 text-accent"
                  : "text-muted hover:bg-surface hover:text-text"
              )}
            >
              <Icon size={16} />
              <span>{label}</span>
            </Link>
          );
        })}
      </nav>
    </aside>
  );
}

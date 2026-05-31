import "./globals.css";
import type { Metadata } from "next";
import { ReactNode } from "react";
import { QueryProvider } from "@/components/QueryProvider";
import { Sidebar } from "@/components/Sidebar";
import { HealthBadge } from "@/components/HealthBadge";

export const metadata: Metadata = {
  title: "YK iOS Orchestrator",
  description: "Yapı Kredi iOS Daily Orchestrator",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="tr">
      <body>
        <QueryProvider>
          <div className="flex h-screen overflow-hidden">
            <Sidebar />
            <main className="flex-1 overflow-y-auto scrollbar-thin">
              <header className="border-b border-border px-6 py-3 flex items-center justify-between bg-surface/30 sticky top-0 backdrop-blur z-10">
                <div className="text-sm text-muted">Lokal — VPN bağlı olmalı</div>
                <HealthBadge />
              </header>
              <div className="p-6">{children}</div>
            </main>
          </div>
        </QueryProvider>
      </body>
    </html>
  );
}

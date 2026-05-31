import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

// API base resolution sırası:
//   1) window.__YKORCH_API_BASE__   ← Swift kabuk (.app) tarafından inject edilir (dinamik port)
//   2) NEXT_PUBLIC_API_URL          ← build-time ENV (dev veya CI)
//   3) "http://127.0.0.1:8765"      ← dev fallback (uvicorn varsayılan portu)
//
// Static export'ta SSR yok; window check runtime'da (browser/WKWebView) çalışır.
declare global {
  interface Window {
    __YKORCH_API_BASE__?: string;
  }
}

function resolveApiBase(): string {
  if (typeof window !== "undefined" && window.__YKORCH_API_BASE__) {
    return window.__YKORCH_API_BASE__;
  }
  return process.env.NEXT_PUBLIC_API_URL || "http://127.0.0.1:8765";
}

export const API_BASE = resolveApiBase();

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`API ${res.status}: ${text}`);
  }
  return res.json() as Promise<T>;
}

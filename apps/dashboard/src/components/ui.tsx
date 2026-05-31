"use client";

import { cn } from "@/lib/utils";
import { ButtonHTMLAttributes, HTMLAttributes, TextareaHTMLAttributes, InputHTMLAttributes, forwardRef } from "react";

export const Button = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" | "danger" }>(
  function Button({ className, variant = "primary", ...props }, ref) {
    const styles =
      variant === "primary"
        ? "bg-accent text-bg hover:bg-accent/90"
        : variant === "danger"
          ? "bg-danger text-bg hover:bg-danger/90"
          : "bg-surface text-text border border-border hover:bg-border/30";
    return (
      <button
        ref={ref}
        className={cn(
          "inline-flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed",
          styles,
          className
        )}
        {...props}
      />
    );
  }
);

export function Card({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "rounded-lg border border-border bg-surface/60 p-4",
        className
      )}
      {...props}
    />
  );
}

export function CardTitle({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("text-sm font-semibold mb-3", className)} {...props} />;
}

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(
  function Textarea({ className, ...props }, ref) {
    return (
      <textarea
        ref={ref}
        className={cn(
          "w-full bg-bg border border-border rounded-md px-3 py-2 text-sm font-mono outline-none focus:border-accent/60 resize-y min-h-[120px]",
          className
        )}
        {...props}
      />
    );
  }
);

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(
  function Input({ className, ...props }, ref) {
    return (
      <input
        ref={ref}
        className={cn(
          "w-full bg-bg border border-border rounded-md px-3 py-1.5 text-sm outline-none focus:border-accent/60",
          className
        )}
        {...props}
      />
    );
  }
);

export function Badge({ className, ...props }: HTMLAttributes<HTMLSpanElement>) {
  return (
    <span
      className={cn(
        "inline-flex items-center px-2 py-0.5 text-[11px] rounded bg-border/40 text-muted",
        className
      )}
      {...props}
    />
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="text-center py-10">
      <div className="text-sm font-medium">{title}</div>
      {hint && <div className="text-xs text-muted mt-1">{hint}</div>}
    </div>
  );
}

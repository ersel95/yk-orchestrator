import { redirect } from "next/navigation";

// Daily standup özelliği kaldırıldı; ana sayfa artık PR'lara yönlendiriyor.
export default function HomePage() {
  redirect("/pull-requests");
}

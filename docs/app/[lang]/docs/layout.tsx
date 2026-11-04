import { source } from "@/lib/source";
import { DocsLayout } from "fumadocs-ui/layouts/notebook";
import { baseOptions } from "@/lib/layout.shared";

export default async function Layout({
  params,
  children,
}: LayoutProps<"/[lang]/docs">) {
  const { lang } = await params;
  const base = baseOptions(lang);
  return (
    <DocsLayout
      {...base}
      nav={{ ...base.nav, mode: "top" }}
      tree={source.getPageTree(lang)}
    >
      {children}
    </DocsLayout>
  );
}

"use client";
import SearchDialog from "@/components/search";
import type { I18nProviderProps } from "fumadocs-ui/contexts/i18n";
import { RootProvider } from "fumadocs-ui/provider/next";
import { type ReactNode } from "react";

export function Provider({
  dir,
  i18n,
  children,
}: {
  dir: "ltr" | "rtl";
  i18n: I18nProviderProps;
  children: ReactNode;
}) {
  return (
    <RootProvider dir={dir} i18n={i18n} search={{ SearchDialog }}>
      {children}
    </RootProvider>
  );
}

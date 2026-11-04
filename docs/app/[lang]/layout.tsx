import { i18nProvider } from "fumadocs-ui/i18n";
import type { Metadata } from "next";
import { Inter } from "next/font/google";
import { Provider } from "@/components/provider";
import { i18n } from "@/lib/i18n";
import { translations } from "@/lib/layout.shared";
import "../global.css";

const inter = Inter({
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://swipt.io"),
};

export function generateStaticParams() {
  return i18n.languages.map((lang) => ({ lang }));
}

export default async function Layout({
  params,
  children,
}: LayoutProps<"/[lang]">) {
  const { lang } = await params;
  const dir = ["ar", "he", "ur"].includes(lang) ? "rtl" : "ltr";
  return (
    <html
      lang={lang}
      dir={dir}
      className={inter.className}
      suppressHydrationWarning
    >
      <body className="flex flex-col min-h-screen">
        <Provider dir={dir} i18n={i18nProvider(translations, lang)}>
          {children}
        </Provider>
      </body>
    </html>
  );
}

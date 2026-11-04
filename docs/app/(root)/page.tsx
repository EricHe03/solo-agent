import { i18n } from "@/lib/i18n";
import { docsRoute } from "@/lib/shared";

const redirect = `
const languages = ${JSON.stringify(i18n.languages)}.map((tag) => [tag, new Intl.Locale(tag).maximize()]);
const preferred = navigator.languages.map((tag) => {
  const { language, script, region } = new Intl.Locale(tag).maximize();
  const candidates = languages.filter(([, locale]) => locale.language === language && locale.script === script);
  return candidates.find(([, locale]) => locale.region === region) ?? candidates[0];
}).find(Boolean);
location.replace("/" + (preferred?.[0] ?? ${JSON.stringify(i18n.defaultLanguage)}) + ${JSON.stringify(docsRoute)});
`;

export default function RootPage() {
  return (
    <>
      <script dangerouslySetInnerHTML={{ __html: redirect }} />
      <noscript>
        <meta httpEquiv="refresh" content={`0;url=/${i18n.defaultLanguage}${docsRoute}`} />
      </noscript>
    </>
  );
}

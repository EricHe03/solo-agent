import { i18n } from "@/lib/i18n";

const redirect = `
const languages = ${JSON.stringify(i18n.languages)};
const preferred = navigator.languages.flatMap((tag) => {
  const base = tag.toLowerCase().split("-")[0];
  return languages.filter((language) => language.toLowerCase().split("-")[0] === base);
})[0];
location.replace("/" + (preferred ?? ${JSON.stringify(i18n.defaultLanguage)}));
`;

export default function RootPage() {
  return (
    <>
      <script dangerouslySetInnerHTML={{ __html: redirect }} />
      <noscript>
        <meta httpEquiv="refresh" content={`0;url=/${i18n.defaultLanguage}`} />
      </noscript>
    </>
  );
}

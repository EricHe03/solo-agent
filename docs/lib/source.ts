import { llms, loader, PathUtils } from "fumadocs-core/source";
import { i18n } from "./i18n";
import { docsRoute } from "./shared";
import { defineCollections } from "fumadocs-mdx/macro";
import { pageSchema } from "fumadocs-core/source/schema";
import { navigation } from "./navigation";

const docs = defineCollections({
  type: "doc",
  dir: "content/docs",
  schema: pageSchema,
  postprocess: {
    includeProcessedMarkdown: true,
  },
});

const translations = defineCollections({
  type: "doc",
  dir: "content/translations",
  schema: pageSchema,
  postprocess: {
    includeProcessedMarkdown: true,
  },
});

const content = docs.toFumadocsSource();
content.files.push(
  ...translations.toFumadocsSource().files,
  ...Object.entries(navigation).flatMap(([folder, { titles, ...meta }]) =>
    Object.entries(titles).map(([lang, title]) => ({
      type: "meta" as const,
      path: PathUtils.joinPath(folder, `meta.${lang}.json`),
      data: { ...meta, title },
    })),
  ),
);

// See https://fumadocs.dev/docs/headless/source-api for more info
export const source = loader({
  baseUrl: docsRoute,
  i18n,
  source: content,
  plugins: [],
});

export const docsLlms = llms(source, {
  renderPage: async (page) => `# ${page.data.title} (${page.url})

${await page.data.getText("processed")}`,
});

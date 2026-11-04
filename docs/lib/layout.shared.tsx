import { zhCN } from "@fumadocs/language/zh-cn";
import { zhTW } from "@fumadocs/language/zh-tw";
import { uiTranslations } from "fumadocs-ui/i18n";
import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import Image from "next/image";
import { i18n } from "./i18n";
import { appName, docsRoute, gitConfig } from "./shared";
import uiStrings from "./translations.json";

export const translations = i18n
  .translations()
  .extend(uiTranslations())
  .add(uiStrings)
  .preset("zh-Hans", zhCN())
  .preset("zh-Hant", zhTW());

export function baseOptions(locale: string): BaseLayoutProps {
  return {
    nav: {
      title: (
        <>
          <Image src="/scroll.svg" alt="" width={20} height={20} />
          {appName}
        </>
      ),
      url: `/${locale}${docsRoute}`,
    },
    githubUrl: `https://github.com/${gitConfig.user}/${gitConfig.repo}`,
  };
}

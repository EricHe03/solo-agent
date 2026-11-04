import { zhCN } from "@fumadocs/language/zh-cn";
import { uiTranslations } from "fumadocs-ui/i18n";
import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import Image from "next/image";
import { i18n } from "./i18n";
import { appName, gitConfig } from "./shared";

export const translations = i18n
  .translations()
  .extend(uiTranslations())
  .add({ en: { displayName: "English" } })
  .preset("zh-Hans", zhCN());

export function baseOptions(locale: string): BaseLayoutProps {
  return {
    nav: {
      title: (
        <>
          <Image src="/scroll.svg" alt="" width={20} height={20} />
          {appName}
        </>
      ),
      url: `/${locale}`,
    },
    githubUrl: `https://github.com/${gitConfig.user}/${gitConfig.repo}`,
  };
}

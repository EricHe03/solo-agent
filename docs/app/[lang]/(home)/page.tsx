import Image from "next/image";
import Link from "next/link";
import { redirect } from "next/navigation";
import { docsRoute } from "@/lib/shared";
import copy from "./copy.json";

export default async function HomePage({ params }: PageProps<"/[lang]">) {
  const { lang } = await params;
  redirect(`/${lang}${docsRoute}`);
  const text = copy[lang as keyof typeof copy];
  return (
    <main className="mx-auto flex w-full max-w-5xl flex-1 flex-col items-center px-6 py-20 text-center">
      <Image src="/scroll.svg" alt="" width={112} height={112} priority />
      <h1 className="mt-6 text-5xl font-semibold tracking-tight">Swipt</h1>
      <p className="mt-4 text-xl text-fd-muted-foreground">{text.tagline}</p>
      <Link
        href={`/${lang}/docs`}
        className="mt-8 rounded-full bg-fd-primary px-5 py-2.5 text-sm font-medium text-fd-primary-foreground"
      >
        {text.read}
      </Link>
    </main>
  );
}

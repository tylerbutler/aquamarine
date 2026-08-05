import starlight from "@astrojs/starlight";
import a11yEmoji from "@fec/remark-a11y-emoji";
import { defineConfig } from "astro/config";
import starlightHeadingBadges from "starlight-heading-badges";
import starlightLinksValidator from "starlight-links-validator";
import starlightLlmsTxt from "starlight-llms-txt";

// https://astro.build/config
export default defineConfig({
	site: "https://aquamarine.tylerbutler.com",
	prefetch: {
		defaultStrategy: "hover",
		prefetchAll: true,
	},
	integrations: [
		starlight({
			title: "Aquamarine",
			editLink: {
				baseUrl: "https://github.com/tylerbutler/aquamarine/edit/main/website/",
			},
			description:
				"Protocol-agnostic Beryl-style WebSocket channel client for Gleam on the BEAM.",
			head: [
				{
					tag: "meta",
					attrs: {
						property: "og:image",
						content: "https://aquamarine.tylerbutler.com/og-image.png",
					},
				},
				{
					tag: "meta",
					attrs: {
						property: "og:image:width",
						content: "1200",
					},
				},
				{
					tag: "meta",
					attrs: {
						property: "og:image:height",
						content: "630",
					},
				},
				{
					tag: "meta",
					attrs: {
						property: "og:image:alt",
						content:
							"Aquamarine: a clear channel runtime for Gleam.",
					},
				},
				{
					tag: "meta",
					attrs: {
						name: "twitter:card",
						content: "summary_large_image",
					},
				},
				{
					tag: "meta",
					attrs: {
						name: "twitter:image",
						content: "https://aquamarine.tylerbutler.com/og-image.png",
					},
				},
			],
			lastUpdated: true,
			logo: {
				src: "./src/assets/aquamarine-logo.webp",
				alt: "Aquamarine logo",
			},
			favicon: "favicon.png",
			customCss: [
				"@fontsource-variable/commissioner/wght.css",
				"@fontsource-variable/sora/wght.css",
				"@fontsource-variable/jetbrains-mono/wght.css",
				"./src/styles/fonts.css",
				"./src/styles/custom.css",
			],
			plugins: [
				starlightLlmsTxt(),
				starlightHeadingBadges(),
				starlightLinksValidator(),
			],
			sidebar: [
				{
					label: "Start here",
					items: [
						{ label: "Introduction", link: "/" },
						{ label: "Getting started", link: "/getting-started/" },
					],
				},
				{
					label: "Guides",
					items: [
						{ label: "Channel lifecycle", link: "/guides/channels/" },
						{ label: "Codecs", link: "/guides/codecs/" },
						{ label: "Phoenix and Beryl", link: "/guides/phoenix/" },
						{
							label: "Heartbeats and refs",
							link: "/guides/heartbeats-and-refs/",
						},
						{ label: "Error handling", link: "/guides/error-handling/" },
					],
				},
				{
					label: "Reference",
					items: [
						{ label: "Beryl ecosystem", link: "/reference/ecosystem/" },
						{ label: "API overview", link: "/reference/api/" },
					],
				},
			],
			social: [
				{
					icon: "github",
					label: "GitHub",
					href: "https://github.com/tylerbutler/aquamarine",
				},
			],
		}),
	],
	markdown: {
		smartypants: false,
		remarkPlugins: [a11yEmoji],
	},
});

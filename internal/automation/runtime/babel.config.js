module.exports = (api) => {
  api.cache(true);
  return {
    presets: ["babel-preset-expo"],
    overrides: [
      {
        test: (file) => file?.endsWith(".ts") ?? false,
        plugins: [
          [
            "@babel/plugin-transform-typescript",
            { allowDeclareFields: true, allowNamespaces: true },
          ],
        ],
      },
      {
        test: (file) => file?.endsWith(".tsx") ?? false,
        plugins: [
          [
            "@babel/plugin-transform-typescript",
            { allowDeclareFields: true, allowNamespaces: true, isTSX: true },
          ],
        ],
      },
    ],
  };
};

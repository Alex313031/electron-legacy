// ESLint 9 flat config.
const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  {
    ignores: [
      '**/node_modules/**',
      '**/package.json',
      '**/package-lock.json',
      'dist/**',
      'test/**'
    ]
  },
  js.configs.recommended,
  {
    files: [ 'src/**/*.js' ],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'commonjs',
      globals: {
        ...globals.browser,
        ...globals.node,
        ...globals.commonjs
      }
    },
    rules: {
      'no-redeclare': [ 'warn' ]
    }
  }
];

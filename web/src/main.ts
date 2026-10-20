import './styles.css';
import { App, endpointFor } from './app';
import { initI18n, t } from './i18n';

const params = new URLSearchParams(location.search);
initI18n(params);
document.title = t('app.title');

const root = document.getElementById('app');
if (root) {
  void new App(root, params, endpointFor(params, location)).start();
}

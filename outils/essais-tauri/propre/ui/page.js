import { appeler } from './ipc.js';

appeler('etat_appli').then((etat) => {
  document.getElementById('etat').textContent = etat;
});

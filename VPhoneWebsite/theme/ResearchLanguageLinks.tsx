import { useEffect } from 'react';

// The research notes are English only, so on a research page the language
// switcher's links (/zh/research/...) lead nowhere. Send them to that
// language's home instead.
const translated = /^(\/vphone-cli)?\/(zh|ja|ko)\/research(\/|\.html|$)/;

export default function ResearchLanguageLinks() {
  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      const anchor = (event.target as Element | null)?.closest?.('a');
      const href = anchor?.getAttribute('href');
      const match = href ? translated.exec(href) : null;
      if (!match) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      window.location.assign(`${match[1] ?? ''}/${match[2]}/`);
    };
    document.addEventListener('click', onClick, true);
    return () => document.removeEventListener('click', onClick, true);
  }, []);
  return null;
}

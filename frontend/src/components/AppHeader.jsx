export default function AppHeader({ user, isAdmin, onLogout }) {
  return (
    <header>
      <a className="wordmark" href="#top"><span>CF</span> CourseFlow</a>
      <nav>
        {isAdmin && <a href="#admin">Керування</a>}
        <a href="#catalog">Каталог</a>
        <a
          href="http://localhost:3000/d/lms-overview/lms-overview"
          target="_blank"
          rel="noreferrer"
        >
          Grafana ↗
        </a>
      </nav>
      <div className="profile">
        <div><strong>{user?.username || "…"}</strong><span>{user?.role}</span></div>
        <button className="icon-button" onClick={onLogout} title="Вийти">↪</button>
      </div>
    </header>
  );
}

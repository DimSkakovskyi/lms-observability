import { useState } from "react";

import { request } from "../api/client";

export default function AuthScreen({ onAuthenticated }) {
  const [mode, setMode] = useState("login");
  const [username, setUsername] = useState("admin");
  const [password, setPassword] = useState("admin12345");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      if (mode === "register") {
        await request("/api/auth/register", {
          method: "POST",
          body: JSON.stringify({ username, password }),
        });
        setMode("login");
        setMessage("Обліковий запис створено. Тепер увійдіть.");
      } else {
        const data = await request("/api/auth/login", {
          method: "POST",
          body: JSON.stringify({ username, password }),
        });
        onAuthenticated(data.access_token);
      }
    } catch (error) {
      setMessage(error.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="brand-panel">
        <div className="brand-mark">CF</div>
        <p className="eyebrow">Observability-ready LMS</p>
        <h1>Навчання, яке видно наскрізь.</h1>
        <p className="brand-copy">
          Каталог курсів, записи студентів і повний шлях кожного запиту — від
          браузера до події RabbitMQ.
        </p>
        <div className="signal-row">
          <span>Metrics</span><i />
          <span>Logs</span><i />
          <span>Traces</span>
        </div>
      </section>

      <section className="auth-panel">
        <div className="auth-card">
          <p className="eyebrow">CourseFlow</p>
          <h2>{mode === "login" ? "З поверненням" : "Новий студент"}</h2>
          <p className="muted">
            {mode === "login"
              ? "Увійдіть, щоб побачити доступні курси."
              : "Створіть обліковий запис для навчання."}
          </p>
          <form onSubmit={submit}>
            <label>
              Ім’я користувача
              <input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                minLength={3}
                autoComplete="username"
                required
              />
            </label>
            <label>
              Пароль
              <input
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                type="password"
                minLength={8}
                autoComplete={mode === "login" ? "current-password" : "new-password"}
                required
              />
            </label>
            {message && <p className="form-message">{message}</p>}
            <button className="primary-button" disabled={busy}>
              {busy ? "Зачекайте…" : mode === "login" ? "Увійти" : "Зареєструватися"}
            </button>
          </form>
          <button
            className="text-button"
            type="button"
            onClick={() => {
              setMode(mode === "login" ? "register" : "login");
              setMessage("");
              if (mode === "login") {
                setUsername("");
                setPassword("");
              }
            }}
          >
            {mode === "login" ? "Створити новий акаунт" : "У мене вже є акаунт"}
          </button>
          {mode === "login" && (
            <p className="demo-hint">Demo admin: admin / admin12345</p>
          )}
        </div>
      </section>
    </main>
  );
}

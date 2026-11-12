import { useCallback, useState } from "react";

import { TOKEN_KEY } from "./api/client";
import AuthScreen from "./components/AuthScreen";
import Dashboard from "./pages/Dashboard";

export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY));

  function authenticated(nextToken) {
    localStorage.setItem(TOKEN_KEY, nextToken);
    setToken(nextToken);
  }

  const logout = useCallback(() => {
    localStorage.removeItem(TOKEN_KEY);
    setToken(null);
  }, []);

  return token ? (
    <Dashboard token={token} onLogout={logout} />
  ) : (
    <AuthScreen onAuthenticated={authenticated} />
  );
}

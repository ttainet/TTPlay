import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { getUserToken, setUserToken, userApi } from '../api/userClient';
import { useApp } from './AppContext';
import type { HouseholdInfo, MemberView, UserPrincipal } from '../types';

interface UserContextValue {
  loading: boolean;
  principal: UserPrincipal | null;
  household: HouseholdInfo | null;
  members: MemberView[];
  refreshUserAuth: () => Promise<void>;
  userLogout: () => Promise<void>;
  setHouseholdLocal: (hh: HouseholdInfo) => void;
}

const UserContext = createContext<UserContextValue | null>(null);

export const UserProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { toast } = useApp();
  const [loading, setLoading] = useState(true);
  const [principal, setPrincipal] = useState<UserPrincipal | null>(null);
  const [household, setHousehold] = useState<HouseholdInfo | null>(null);
  const [members, setMembers] = useState<MemberView[]>([]);

  const refreshUserAuth = useCallback(async () => {
    if (!getUserToken()) {
      setPrincipal(null);
      setHousehold(null);
      setMembers([]);
      setLoading(false);
      return;
    }
    try {
      const res = await userApi.me();
      setPrincipal(res.principal);
      setHousehold(res.household || null);
      setMembers(res.members || []);
    } catch {
      setUserToken('');
      setPrincipal(null);
      setHousehold(null);
      setMembers([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refreshUserAuth();
  }, [refreshUserAuth]);

  const userLogout = useCallback(async () => {
    try {
      await userApi.logout();
    } catch {
      // ignore logout transport error
    }
    setUserToken('');
    setPrincipal(null);
    setHousehold(null);
    setMembers([]);
    toast('已退出用户面板', 'info');
  }, [toast]);

  const setHouseholdLocal = useCallback((hh: HouseholdInfo) => {
    setHousehold(hh);
  }, []);

  return (
    <UserContext.Provider
      value={{
        loading,
        principal,
        household,
        members,
        refreshUserAuth,
        userLogout,
        setHouseholdLocal,
      }}
    >
      {children}
    </UserContext.Provider>
  );
};

export function useUser(): UserContextValue {
  const ctx = useContext(UserContext);
  if (!ctx) throw new Error('useUser must be used within UserProvider');
  return ctx;
}

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import {
  addCustomItemToCart,
  addProductToCart,
  changeCartItemQuantity,
  removeCartItem,
  type StaffProductSelection,
  type StaffRequestCartItem,
} from "@/supply-requests/staff-request-cart";

// The staff request cart lives above the staff routes so items added from the
// Workspace survive moving to Review and back. It is in-memory only: a reload, sign-out
// or organization switch starts a fresh cart, and nothing is ever submitted from here.

export type RequestAgainSource = {
  requestId: string;
  submittedAt: string;
  unavailable: Array<{ lineId: string; name: string; quantity: number }>;
};

type StaffCart = {
  items: StaffRequestCartItem[];
  notes: string;
  againSource: RequestAgainSource | null;
  setItems: Dispatch<SetStateAction<StaffRequestCartItem[]>>;
  setNotes: (notes: string) => void;
  dismissAgainSource: () => void;
  addProduct: (selection: StaffProductSelection, quantity?: number) => void;
  addCustom: (name: string, quantity?: number) => void;
  changeQuantity: (key: string, delta: number) => void;
  remove: (key: string) => void;
  replace: (items: StaffRequestCartItem[], againSource?: RequestAgainSource | null) => void;
  clear: () => void;
};

const StaffCartContext = createContext<StaffCart | null>(null);

export function StaffCartProvider({
  children,
  initialItems = [],
}: {
  children: ReactNode;
  initialItems?: StaffRequestCartItem[];
}) {
  const [items, setItems] = useState<StaffRequestCartItem[]>(initialItems);
  const [notes, setNotes] = useState("");
  const [againSource, setAgainSource] = useState<RequestAgainSource | null>(null);

  const addProduct = useCallback((selection: StaffProductSelection, quantity = 1) => {
    setItems((current) => addProductToCart(current, crypto.randomUUID(), selection, quantity));
  }, []);
  const addCustom = useCallback((name: string, quantity = 1) => {
    setItems((current) => addCustomItemToCart(current, crypto.randomUUID(), name, quantity));
  }, []);
  const changeQuantity = useCallback((key: string, delta: number) => {
    setItems((current) => changeCartItemQuantity(current, key, delta));
  }, []);
  const remove = useCallback((key: string) => {
    setItems((current) => removeCartItem(current, key));
  }, []);
  const replace = useCallback(
    (next: StaffRequestCartItem[], source: RequestAgainSource | null = null) => {
      setItems(next);
      setNotes("");
      setAgainSource(source);
    },
    [],
  );
  const dismissAgainSource = useCallback(() => setAgainSource(null), []);
  const clear = useCallback(() => {
    setItems([]);
    setNotes("");
    setAgainSource(null);
  }, []);

  const value = useMemo<StaffCart>(
    () => ({
      items,
      notes,
      againSource,
      setItems,
      setNotes,
      dismissAgainSource,
      addProduct,
      addCustom,
      changeQuantity,
      remove,
      replace,
      clear,
    }),
    [
      items,
      notes,
      againSource,
      dismissAgainSource,
      addProduct,
      addCustom,
      changeQuantity,
      remove,
      replace,
      clear,
    ],
  );
  return <StaffCartContext.Provider value={value}>{children}</StaffCartContext.Provider>;
}

export function useStaffCart(): StaffCart {
  const cart = useContext(StaffCartContext);
  if (!cart) throw new Error("useStaffCart must be used inside StaffCartProvider");
  return cart;
}
